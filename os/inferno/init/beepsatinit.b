implement Init;

#
# Flight configuration: the board comes up into the mission, not a
# shell.
#
# This is what doc/pycubed-plan.ms's budget assumes -- a kernel and one
# purpose-built Dis program, never the shell -- so it is also how the
# mission's own share of that budget gets measured.  os/inferno/init/
# armv7minit.b is the same thing with a shell at the end instead.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "radiocal.m";
	radiocal: Radiocal;

Init: module
{
	init:	fn();
};

Mission: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init()
{
	mission: Mission;

	sys = load Sys Sys->PATH;
	sys->print("beepsat init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);

	# The board's own files: os/inferno/armv7m/devarch.c.  A kernel
	# without the arch device fails this bind and the mission then
	# says which file it could not open.
	sys->bind("#P", "/dev", sys->MAFTER);
	sys->bind("#W", "/dev", sys->MAFTER);

	# THE RADIO'S OWN CALIBRATION, BEFORE THE MISSION TOUCHES IT.
	#
	# The mission writes packets to /dev/radio0/data and nothing in
	# it writes freq or ppm, so without this the radio sits at
	# whatever the driver's register table left -- which on this
	# bench means no second board can hear it.  The two clicker 2
	# crystals are 64ppm apart, about 59kHz at 915MHz, and the
	# channel filter is 25: a beacon written, accepted by the driver
	# and radiated into the wrong place looks exactly like a radio
	# that works.  doc/radio-plan.ms item 8 is why this file exists
	# at all.
	#
	# Here and not in the mission, for the same reason
	# os/inferno/init/armv7max25.b does it here: which crystal this
	# board has is configuration, not mission logic, and a task that
	# restarts should not re-tune the radio.
	#
	# Soft-failing, like armv7max25, and for the same reason -- a
	# satellite that will not start is no better than one on the
	# wrong frequency -- but it says which, on a line of its own,
	# because the two have to be told apart from the ground.
	radiotune();

	# DEPLOYED, WHICH IS THE STATE A MISSION STARTS IN.
	#
	# A satellite leaves its deployer tumbling, with its charger
	# seeing sun.  The simulated parts come up still and not
	# charging, which is a state no spacecraft is ever in, so nothing
	# the flight software does about attitude would ever run.
	#
	# Set here and not in the mission, for the same reason the
	# crystal correction is: this is the initial condition of the
	# BENCH, not a decision the mission makes.  On a board with the
	# real parts fitted these writes fail and say so, and the mission
	# gets whatever the hardware is actually doing -- which is the
	# right answer in both cases.
	deployed();

	mission = load Mission "/dis/pycubed/beepsat.dis";
	if(mission == nil){
		sys->print("init: load beepsat: %r\n");
		exit;
	}
	sys->print("BEEPSAT-INIT-OK\n");
	mission->init(nil, "beepsat" :: nil);
}

# One ctl write, with the answer read back where there is one.
put(fd: ref Sys->FD, s: string): int
{
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b){
		sys->print("beepsat: radio %s: %r\n", s);
		return 0;
	}
	return 1;
}

radiotune()
{
	ctl := sys->open("/dev/radio0/ctl", Sys->OWRITE);
	if(ctl == nil){
		sys->print("beepsat: no /dev/radio0/ctl: %r -- no radio on "
			+ "this board, so nothing to tune\n");
		return;
	}
	# 915MHz and not the driver's default, because that is the band
	# this bench transmits in: 902 to 928 at Part 15 levels.
	if(!put(ctl, "freq 915000000")){
		sys->print("BEEPSAT-NOFREQ\n");
		return;
	}
	radiocal = load Radiocal Radiocal->PATH;
	if(radiocal == nil){
		sys->print("beepsat: load %s: %r -- the driver's crystal "
			+ "stands and a peer 64ppm away will not hear this "
			+ "board\n", Radiocal->PATH);
		return;
	}
	radiocal->init();
	uid := radiocal->boarduid(Radiocal->Uid);
	if(uid == nil){
		sys->print("beepsat: cannot read %s: %r -- this board does "
			+ "not know whose calibration it would apply\n",
			Radiocal->Uid);
		return;
	}
	sys->print("beepsat: uid %s\n", uid);
	want := array[3] of string;
	want[0] = "ppb";
	want[1] = "rssioffset";
	want[2] = "csthr";
	# Both sources with the store winning, which is what current()
	# is for: #P/cal is what this board has measured since its image
	# was built.
	(got, nil, bad, err) := radiocal->current(Radiocal->Cal, uid, want);
	if(bad > 0)
		sys->print("beepsat: %d unparsable pairs in %s\n", bad,
			Radiocal->Cal);
	if(err != nil){
		sys->print("beepsat: no calibration for this board in %s or "
			+ "%s: %s -- the driver's defaults stand\n",
			Radiocal->Cal, Radiocal->Store, err);
		return;
	}
	if(got[0] != nil && put(ctl, "ppm " + got[0]))
		sys->print("beepsat: ppm %s\n", got[0]);
	if(got[1] != nil)
		put(ctl, "rssioffset " + got[1]);
	if(got[2] != nil)
		put(ctl, "csthr " + got[2]);
}

deployed()
{
	fd := sys->open("/dev/imu.ctl", Sys->OWRITE);
	if(fd == nil){
		sys->print("beepsat: no /dev/imu.ctl: %r -- the parts are"
			+ " real or absent, either way not scripted\n");
		return;
	}
	if(put(fd, "tumble"))
		sys->print("beepsat: tumbling, as a deployed satellite is\n");
	# The pack BEFORE the charger, which is the order that reads
	# right even though the charger no longer depends on it: a
	# satellite has a battery at some state of charge and then has
	# input, not the other way round.
	pfd := sys->open("/dev/power.ctl", Sys->OWRITE);
	if(pfd != nil){
		# The pack follows the simulated panel rather than the
		# part's VBAT rail, because the thing being demonstrated is
		# whether attitude control keeps it charged -- and #P/arch
		# says SCRIPTED while it does.
		if(put(pfd, "battery sim"))
			sys->print("beepsat: battery is the scripted pack\n");
		put(pfd, "volts 3700");
	}
	cfd := sys->open("/dev/charge.ctl", Sys->OWRITE);
	if(cfd != nil && put(cfd, "in on"))
		sys->print("beepsat: charger sees sun\n");
}
