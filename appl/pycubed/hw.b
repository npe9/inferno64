implement Hw;

#
# The mission's view of the hardware: a library that opens the files
# module/pycubedhw.m describes and parses them.
#
# This is Limbo wrapping a file interface, which is what appl/lib/
# daytime.b does with /dev/time, and it is the reason this module's
# PATH is a .dis: it genuinely is Limbo.  Nothing below touches a
# register.  Whatever serves the directory does that -- on a real board
# the C drivers of phase 2; on a board without the parts,
# os/inferno/mps2/archfiles.c, which registers the same files through
# addarchfile() and says in /dev/arch that every reading is invented.
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

# The radio, when one is fitted: #W/radio0/data, bound at /dev by the
# init.  One write is one packet, which is why this is a file and not a
# Medium at /net/ether0 -- ssl(3) attaches to a file descriptor ("fd m"
# on its ctl file) and ssl->connect() takes a ref Sys->FD, so an
# authenticated, encrypted Styx link runs straight over this with no IP
# stack under it.  See radio(3) and "What Inferno already answers" in
# doc/pycubed-plan.ms, which also has the thing that does not fall out
# for free: the payload budget is 251 bytes and os/inferno/port/
# devmnt.c refuses an msize below 256.
#
# No board in this tree has a radio on it.  mps2 under a QEMU carrying
# tools/qemu-patches 0027-0029 and started with "-machine radio=on" has
# a modelled one; everything else opens nothing and says so.
fradio: ref Sys->FD;

haveradio(): int
{
	if(fradio == nil)
		fradio = sys->open("/dev/radio0/data", Sys->ORDWR);
	return fradio != nil;
}

radiosend(b: array of byte): int
{
	if(!haveradio())
		return -1;
	return sys->write(fradio, b, len b);
}

# The same descriptor, read.  One read is one packet: radio(3) serves
# #W/radio0/data that way, so a short buffer truncates a packet rather
# than leaving the rest for the next read, and the caller's buffer has
# to be at least the carrier's iounit.
#
# Blocks until a packet arrives.  Nothing here times out, because a
# satellite with nothing to hear should wait rather than spin, and the
# process that calls this has nothing else to do.
radiorecv(b: array of byte): int
{
	if(!haveradio())
		return -1;
	return sys->read(fradio, b, len b);
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
