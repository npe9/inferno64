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
		if(!hw->haveradio()){
			# The Python guards keying the transmitter with
			# ANTENNA_ATTACHED because nobody knows whether an
			# antenna is on the board.  Here there is no radio
			# at all, which is a stronger statement and the
			# honest one: see module/pycubedhw.m.
			debug("beacon", "no radio on this board, nothing sent");
			continue;
		}
		# The Python beacons the string "Hello World!"; this sends
		# the same thing, so the two can be read against each
		# other.  A real beacon carries telemetry, and telemetry
		# here is a file the ground reads over the link rather
		# than a packet format -- see doc/pycubed-plan.ms.
		b := array of byte "Hello World!";
		if(hw->radiosend(b) < 0)
			debug("beacon", sys->sprint("send: %r"));
		else
			debug("beacon", "sent " + string len b + " bytes");
	}
}

# Over-the-air commands -- cdh.py.
#
# The Python checks a four-byte pass-code and then dispatches on a
# two-byte command through a dict.  The pass-code is a demonstration in
# the original and says so; it is not a security mechanism and is not
# presented as one here either.
#
# It is also not what this should end up as, and the reason is written
# down in doc/pycubed-plan.ms under "What Inferno already answers":
# a pass-code that crosses the air in clear is a constant where Inferno
# has a mechanism.  The link should carry Styx, authenticated with
# keyring->auth() and encrypted with ssl(3) before any message crosses
# it, and then there is no command table -- the ground reads and writes
# files in a namespace this program exported, and "HR" is a write to
# /dev/reboot done from the other end rather than a case in a switch.
# What is here is the port of what the example does, kept so that the
# two can be read against each other.
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

# DETUMBLE, WHICH IS THE FIRST THING A CUBESAT DOES AND THE FIRST THING
# THIS SOFTWARE DOES THAT KEEPS ITSELF ALIVE.
#
# A satellite leaves its deployer tumbling.  Tumbling, its panels sweep
# through the sun and charge in pulses whose average is below the draw,
# so the battery falls; held with the panels toward the sun it charges
# steadily.  So this is not a demonstration of control -- it is what
# keeps the board powered, and /dev/battery is the figure that says
# whether it worked.
#
# THE LAW IS B-DOT, which is what CubeSats actually fly, and the whole
# of it is: command a magnetic dipole opposing the measured rate of
# change of the field.
#
#	m = -k dB/dt
#
# It needs no attitude estimate, no sun sensor, no model of the orbit
# and no inertia tensor -- only two magnetometer readings and the time
# between them.  That is why it is what flies: the one thing a freshly
# deployed satellite has is a magnetometer, and the one thing it does
# not have is knowledge of where it is pointing.
#
# It takes energy out of the tumble and cannot add any, so the failure
# mode is "slow" rather than "worse" -- unless the sign is wrong, which
# drives the rate UP, and that is the thing worth catching on a bench.
# The gain is in the sign too: k negative here would spin the satellite
# up, so the test is that the rate FALLS.
# THE GAIN, AND IT WAS TWENTY-THREE TIMES TOO BIG.
#
# As a plain multiplier of 24 this commanded a dipole of about 3770
# milli-A.m^2 for the 157 milli-gauss a second a 20 deg/s tumble
# produces -- and the rate ROSE, 23.0 to 28.6 deg/s over a minute,
# monotonically.
#
# That reads as an inverted sign and is not one.  The model was tested
# on its own, from a prompt, with a dipole worked out by hand from
# m = -k dB/dt for the attitude it was actually at: 20000 milli-deg/s
# fell to 18995, 18577, 18912, 18699 -- damping, with a ripple because a
# FIXED dipole gives a sinusoidal torque as the body turns.  So the
# model damps and the law is right; what was wrong was a loop driven
# hard enough to overshoot between samples, since the body turns forty
# degrees in the two seconds between them.
#
# Expressed as a ratio now so it can be moved without changing units:
# 1300/1000 gives about 204 for that same tumble, which is the order
# the hand test damped at.
Dtgain:		con 1300;	# numerator
Dtscale:	con 1000;	# over this
Dtperiod:	con 2000;	# ms between samples
Dtdeadband:	con 300;	# milli-degrees/s to stop at

detumbletask()
{
	last := hw->imumag();
	if(last == nil){
		debug("detumble", "no magnetometer, nothing to detumble by");
		return;
	}
	settled := 0;
	for(;;){
		sys->sleep(Dtperiod);
		b := hw->imumag();
		if(b == nil)
			continue;
		# dB/dt in milli-gauss a second, from two readings and the
		# interval between them.  No filter: a first-order law with
		# an unfiltered derivative is what the textbooks give and
		# what the noise in the sensor is for.
		dx := ((b[0] - last[0]) * 1000) / Dtperiod;
		dy := ((b[1] - last[1]) * 1000) / Dtperiod;
		dz := ((b[2] - last[2]) * 1000) / Dtperiod;
		last = b;
		# The gyro is NOT used by the law -- B-dot does not need it
		# -- but it is what says whether the law is working, so it
		# is read for the report and for the deadband.
		g := hw->imugyro();
		rate := 0;
		if(g != nil){
			for(i := 0; i < 3; i++){
				v := g[i];
				if(v < 0)
					v = -v;
				if(v > rate)
					rate = v;
			}
			# The gyro is milli-degrees a second, which is
			# what module/pycubedhw.m says and what the
			# driver now delivers.  It used to divide to
			# whole degrees and then add ten milli-units of
			# noise to them, which is ten DEGREES on a rate
			# of twenty -- so this task saw no trend and the
			# first run of it looked like a controller that
			# did nothing.
		}
		if(rate < Dtdeadband){
			# Stop commanding.  A magnetorquer left energised
			# costs power for ever and a satellite that has
			# stopped tumbling has nothing to damp; this is the
			# difference between a controller and a load.
			if(!settled){
				hw->torque(0, 0, 0);
				settled = 1;
				debug("detumble", "settled, torquers off");
			}
			continue;
		}
		settled = 0;
		if(hw->torque(-(Dtgain*dx)/Dtscale, -(Dtgain*dy)/Dtscale,
		    -(Dtgain*dz)/Dtscale) < 0){
			debug("detumble", sys->sprint("torque: %r"));
			return;
		}
		debug("detumble", sys->sprint("rate %d.%.3d deg/s, "
			+ "dB/dt %d %d %d, m %d %d %d",
			rate/1000, rate%1000, dx, dy, dz,
			-(Dtgain*dx)/Dtscale, -(Dtgain*dy)/Dtscale,
			-(Dtgain*dz)/Dtscale));
	}
}

cdhtask()
{
	if(!hw->haveradio()){
		debug("cdh", "no radio on this board, nothing to listen to");
		return;
	}
	# The carrier's own packet size.  Asking the radio rather than
	# naming a number: #W/radio0/data's iounit is what one read can
	# return, and a buffer short of it would truncate every command.
	b := array[256] of byte;
	for(;;){
		n := hw->radiorecv(b);
		if(n < 0){
			debug("cdh", sys->sprint("recv: %r"));
			return;
		}
		if(n == 0)
			continue;
		cdh(b[0:n]);
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
	# THE GROUND'S SIDE OF THE RADIO, which nothing read until now.
	#
	# cdh() has been in this file since the port with no caller: the
	# Python's main loop polls the radio inside its scheduler and
	# there was no equivalent here, so the satellite beaconed and
	# could not be told anything.  A process of its own rather than a
	# poll, because radiorecv() blocks and because that is what
	# Inferno has instead of a cooperative scheduler -- the same
	# argument that deleted lib/tasko.
	spawn detumbletask();
	spawn cdhtask();
	spawn blinktask();
	spawn timetask(s.boottime);
	spawn vbatttask();
	spawn beacontask();
	sys->print("BEEPSAT-RUNNING 6 tasks\n");

	if(secs <= 0){
		for(;;)
			sys->sleep(60*1000);
	}
	sys->sleep(secs*1000);
	s = ask(sat->Get, nil, 0);
	sys->print("BEEPSAT-DONE vbatt %s boots %d responses %d power %s\n",
		mv(s.vbatt), s.cboot, s.cgsresp, s.powermode);
}
