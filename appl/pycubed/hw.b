implement Hw;

#
# The mission's view of the hardware: a library that opens the files
# module/pycubedhw.m describes and parses them.
#
# This is Limbo wrapping a file interface, which is what appl/lib/
# daytime.b does with /dev/time, and it is the reason this module's
# PATH is a .dis: it genuinely is Limbo.  Nothing below touches a
# register.  Whatever serves the directory does that -- a C device on a
# real board, appl/pycubed/hwsim.b on one without the parts.
#

include "sys.m";
	sys: Sys;
include "pycubedhw.m";

FD: import Sys;

hwdir: string;
fbatt, frgb, fimu: ref FD;

open(name: string, mode: int): ref FD
{
	return sys->open(hwdir + "/" + name, mode);
}

init(dir: string): string
{
	sys = load Sys Sys->PATH;
	hwdir = dir;

	# Opened once and held: a task reading the battery every ten
	# seconds should not pay for a walk each time, and holding the
	# channel is what a device expects.
	fbatt = open("battery", Sys->OREAD);
	frgb = open("rgb", Sys->OWRITE);
	fimu = open("imu", Sys->OREAD);
	if(fbatt == nil || frgb == nil || fimu == nil)
		return sys->sprint("%s: %r", hwdir);
	return nil;
}

source(): string
{
	# Whatever is serving the directory says what it is, if it has
	# anything to say.  A real device has no such file and the
	# absence is the answer.
	fd := open("arch", Sys->OREAD);
	if(fd == nil)
		return hwdir;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return hwdir;
	s := string buf[0:n];
	if(len s > 0 && s[len s-1] == '\n')
		s = s[0:len s-1];
	return s;
}

rdline(fd: ref FD): string
{
	buf := array[256] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

battmv(): int
{
	return int rdline(fbatt);
}

rgb(r, g, b: int)
{
	s := array of byte sys->sprint("%d %d %d", r, g, b);
	sys->write(frgb, s, len s);
}

# There is no radio here.
#
# On a PyCubed the RFM9x is an SX127x on SPI, and its Inferno home is
# devether: a Medium driver puts it at /net/ether0 and the IP stack runs
# over it, the way ethermedium.c and pktmedium.c do for the media this
# tree already has.  That is a driver and a Medium, not a file to read,
# and it is phase 2.  A board without one says so rather than inventing
# traffic: see doc/pycubed-plan.ms.
haveradio(): int
{
	return 0;
}

# "mag x y z", "gyro x y z", "accel x y z" -- one read, three lines, so
# the three axes of one sample come from the same instant.
imuline(want: string): array of int
{
	v := array[3] of {* => 0};
	s := rdline(fimu);
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		(nil, f) := sys->tokenize(hd lines, " \t");
		if(len f == 4 && hd f == want){
			f = tl f;
			for(i := 0; i < 3; i++){
				v[i] = int hd f;
				f = tl f;
			}
			break;
		}
	}
	return v;
}

imumag(): array of int
{
	return imuline("mag");
}

imugyro(): array of int
{
	return imuline("gyro");
}

imuaccel(): array of int
{
	return imuline("accel");
}
