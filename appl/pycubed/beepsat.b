implement Beepsat;

#
# The beep-sat mission, ported from PyCubed's software_example_beepsat.
#
# What the Python does: main.py scans a Tasks/ directory, imports each
# file, builds a task object from it, and registers a coroutine with
# lib/tasko, which then runs them all on one thread by hand.  Each task
# reaches into a shared cubesat object for both state and hardware.
#
# What this does: one process per task, each with its own timer, and one
# process that owns the state and answers on a channel.  lib/tasko is
# not ported -- it is 536 lines that exist because CircuitPython has one
# thread, and Inferno has processes.  The directory scan and the exec()
# that goes with it are not ported either: the tasks are named here, so
# a typo is a compile error rather than a module that silently does not
# run.  See doc/pycubed-plan.ms phase 4.
#
# Frequencies are the Python's, converted from Hz to a period in
# milliseconds: blink 2Hz, vbatt every 10s, time every 20s, beacon every
# 30s.  Priorities are not ported: they order a cooperative scheduler's
# ready list, and these are processes.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "pycubed.m";
	sat: Sat;
	State, Req: import sat;
include "pycubedhw.m";
	hw: Hw;

Beepsat: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

req: chan of ref Req;

# Ask the state server.  Every task goes through this rather than
# holding a reference to the state.
ask(kind: int, name: string, val: int): ref State
{
	reply := chan of ref State;
	req <-= ref Req(kind, name, val, reply);
	return <-reply;
}

debug(task: string, msg: string)
{
	sys->print("%12s | %s\n", task, msg);
}

# millivolts as volts, without formatting a real: these parts have no
# double-precision floating point and the kernel's print does not carry
# a %f for one.  See doc/armv7m-ports.ms.
mv(v: int): string
{
	return sys->sprint("%d.%.2dV", v/1000, (v%1000)/10);
}

blinktask()
{
	on := 0;
	for(;;){
		if(on){
			hw->rgb(0, 0, 0);
			on = 0;
		} else {
			hw->rgb(0, 255, 0);
			on = 1;
		}
		sys->sleep(500);		# 2Hz
	}
}

timetask(boottime: int)
{
	for(;;){
		sys->sleep(20*1000);
		t := sys->millisec()/1000 - boottime;
		debug("time", sys->sprint("%ds since boot", t));
	}
}

# check for low battery condition -- battery_task.py
vbatttask()
{
	timeout := 60*60;		# the Python's 60 minutes
	for(;;){
		sys->sleep(10*1000);		# once every 10s
		s := ask(sat->Setvbatt, nil, hw->battmv());
		cmp := ">";
		if(s.vbatt <= s.vlowbatt)
			cmp = "<";
		debug("vbatt", sys->sprint("%s %s threshold %s",
			mv(s.vbatt), cmp, mv(s.vlowbatt)));
		if(cmp != "<")
			continue;

		ask(sat->Setflag, "lowbatt", 1);
		s = ask(sat->Get, nil, 0);
		if(s.flowbtout){
			debug("vbatt", "lowbatt timeout flag set, skipping");
			continue;
		}
		# The Python stops every other task, drops to minimum
		# power and sleeps in steps until the timeout expires.
		# Stopping the others is what tasko's handles are for;
		# here the power mode is the state every task reads, so
		# setting it is enough and no task has to be killed.
		debug("vbatt", "low battery detected");
		ask(sat->Setpower, "minimum", 0);
		deadline := sys->millisec()/1000 + timeout;
		while(sys->millisec()/1000 < deadline){
			sys->sleep(timeout*1000/10);
			s = ask(sat->Setvbatt, nil, hw->battmv());
			debug("vbatt", sys->sprint("vbatt %s", mv(s.vbatt)));
			if(s.vbatt > s.vlowbatt){
				ask(sat->Setflag, "lowbatt", 0);
				break;
			}
		}
		ask(sat->Setpower, "normal", 0);
		ask(sat->Setflag, "lowbtout", 1);
	}
}

# Transmit a beacon and listen for a reply -- beacon_task.py.
#
# ANTENNA_ATTACHED in the Python guards actually keying the transmitter
# when nobody knows whether an antenna is on the board; it is a policy
# decision and it is kept.  Here it is off, and with the stub behind it
# nothing is transmitted either way.
antennaattached := 0;

beacontask()
{
	for(;;){
		sys->sleep(30*1000);		# once every 30s
		if(antennaattached){
			debug("beacon", "sending beacon");
			hw->radiosend(array of byte "Hello World!");
		} else {
			debug("beacon", "NOT sending beacon (unknown antenna state)");
			hw->radiolisten();
		}
		debug("beacon", "listening 10s for a response");
		resp := hw->radiorecv(10*1000);
		if(resp == nil){
			debug("beacon", "no messages");
		} else {
			s := ask(sat->Bump, "gsresp", 1);
			debug("beacon", sys->sprint("packet received, RSSI %d, responses %d",
				hw->radiorssi(), s.cgsresp));
			cdh(resp);
		}
		hw->radiosleep();
	}
}

# Over-the-air commands -- cdh.py.
#
# The Python checks a four-byte pass-code and then dispatches on a
# two-byte command through a dict.  The pass-code is a demonstration in
# the original and says so; it is not a security mechanism and is not
# presented as one here either.
supersecret := array[] of {byte 16r70, byte 16rba, byte 16rb8, byte 16r43};

cdh(msg: array of byte)
{
	if(len msg < 6){
		debug("cdh", "short packet, not a command");
		return;
	}
	for(i := 0; i < 4; i++)
		if(msg[i] != supersecret[i]){
			debug("cdh", "bad pass-code");
			return;
		}
	cmd := string msg[4:6];
	case cmd {
	"NO" =>
		debug("cdh", "no-op");
	"HR" =>
		# A reset is the kernel's, not a device's: Inferno puts it
		# at /dev/reboot (os/inferno/port/devcons.c).  The Python
		# reaches for microcontroller.on_next_reset() because
		# CircuitPython has no such file.
		debug("cdh", "hard reset");
		fd := sys->open("/dev/reboot", Sys->OWRITE);
		if(fd == nil)
			debug("cdh", sys->sprint("reboot: %r"));
		else {
			b := array of byte "reboot";
			sys->write(fd, b, len b);
		}
	"SD" =>
		debug("cdh", "shutdown");
		ask(sat->Setpower, "minimum", 0);
	"QU" =>
		s := ask(sat->Get, nil, 0);
		debug("cdh", sys->sprint("query: boots %d errors %d responses %d %s",
			s.cboot, s.cstateerr, s.cgsresp, s.powermode));
	* =>
		debug("cdh", "invalid command " + cmd);
	}
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sat = load Sat Sat->PATH;
	if(sat == nil){
		sys->print("beepsat: load %s: %r\n", Sat->PATH);
		return;
	}
	hw = load Hw Hw->PATH;
	if(hw == nil){
		sys->print("beepsat: load %s: %r\n", Hw->PATH);
		return;
	}
	sat->init();

	# beepsat [seconds [hwdir]].  seconds 0 or absent runs forever,
	# which is what a satellite does; a bench wants to stop.
	secs := 0;
	hwdir := "/dev";
	if(tl argv != nil){
		secs = int hd tl argv;
		if(tl tl argv != nil)
			hwdir = hd tl tl argv;
	}

	# os/inferno/port/devpycubed.c serves these, bound into /dev by
	# the init.  See module/pycubedhw.m for the protocol.
	err := hw->init(hwdir);
	if(err != nil){
		sys->print("beepsat: hardware at %s: %s\n", hwdir, err);
		return;
	}

	sys->print("\nBeep-Sat, ported to Limbo\n");
	sys->print("hardware: %s\n\n", hw->source());

	req = chan of ref Req;
	spawn sat->server(req);

	s := ask(sat->Get, nil, 0);
	spawn blinktask();
	spawn timetask(s.boottime);
	spawn vbatttask();
	spawn beacontask();
	sys->print("BEEPSAT-RUNNING 4 tasks\n");

	if(secs <= 0){
		for(;;)
			sys->sleep(60*1000);
	}
	sys->sleep(secs*1000);
	s = ask(sat->Get, nil, 0);
	sys->print("BEEPSAT-DONE vbatt %s boots %d responses %d power %s\n",
		mv(s.vbatt), s.cboot, s.cgsresp, s.powermode);
}
