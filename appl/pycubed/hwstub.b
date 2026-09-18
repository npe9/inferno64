implement Hw;

#
# The hardware boundary with no hardware behind it.
#
# This is not a driver.  It exists so that the mission logic can be run
# and measured on a board that has none of a PyCubed's devices -- there
# is no ADM1176, no RFM9x and no BMX160 on an MPS2 or a Teensy -- and
# every reading it returns is made up.  It says so when it starts and
# the values it returns are named in the source rather than looking like
# measurements.
#
# The real implementations are C, under os/inferno, and are phase 2 of
# doc/pycubed-plan.ms.  What this file fixes is the shape of the
# boundary they have to meet.
#

include "sys.m";
	sys: Sys;
include "pycubedhw.m";

# The battery discharging: the stand-in drops it a little on each
# reading so the low-battery path in the vbatt task can be reached.
vbatt := 4000;

init()
{
	sys = load Sys Sys->PATH;
}

name(): string
{
	return "stub: no hardware, every reading below is invented";
}

battmv(): int
{
	if(vbatt > 3000)
		vbatt -= 40;
	return vbatt;
}

rgb(r, g, b: int)
{
	sys->print("\thw-stub: RGB %d %d %d\n", r, g, b);
}

radiolisten()
{
	sys->print("\thw-stub: radio listen\n");
}

radiosleep()
{
	sys->print("\thw-stub: radio sleep\n");
}

radiosend(msg: array of byte): int
{
	sys->print("\thw-stub: radio send %d bytes: %s\n", len msg, string msg);
	return 0;
}

# Nothing is ever received: there is no radio.  The beacon task's
# receive path is exercised by its timeout, not by invented traffic.
radiorecv(tmo: int): array of byte
{
	sys->sleep(tmo);
	return nil;
}

radiorssi(): int
{
	return -137;
}

imumag(): array of int
{
	return array[] of {0, 0, 0};
}

imugyro(): array of int
{
	return array[] of {0, 0, 0};
}

imuaccel(): array of int
{
	return array[] of {0, 0, 1000};		# 1g down, in milli-g
}

reset()
{
	sys->print("\thw-stub: reset (not resetting anything)\n");
}
