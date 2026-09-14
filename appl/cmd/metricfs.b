implement Metricfs;

#
# metricfs(4) -- the machine's own numbers as a file tree.
#
# doc/inferno-cloud-modern.ms item 13: "logs and metrics as a mountable
# file tree, so that observing a machine is the same operation as
# reading one."  That is the whole idea: there is no metrics protocol
# here, no scrape endpoint and no exposition format.  A monitor reads
# files, and because a namespace can be exported, it reads them on
# another machine with the same code.
#
#	styxlisten -A 'tcp!*!6666' export /n/metric
#	mount -A tcp!host!6666 /n/host
#	cat /n/host/mem/main/used
#
# The numbers are not invented here.  Each leaf is one field of a file
# the kernel already serves, named, so that a reader does not have to
# know that /dev/memory's third column is the high-water mark:
#
#   /dev/sysstat   one line per processor: machno, context switches,
#                  interrupts, system calls, page faults, TLB faults,
#                  TLB purges, load, idle percentage
#                  (os/inferno/port/devcons.c)
#   /dev/memory    one line per pool: cursize, maxsize, high water,
#                  nalloc, nfree, nbrk, largest allocatable, name
#                  (os/inferno/port/alloc.c, poolread)
#   /dev/time      seconds, nanoseconds, ticks, ticks per second
#   /prog          one directory per process
#
# Everything is read when it is read.  There is no sampling interval
# and nothing is cached: a file has the value it had when the read
# happened, which is the only reading a file server can honestly give.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, readbytes: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

Metricfs: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# A qid path is kind<<32 | index<<8 | field, so that a leaf knows
# without a lookup which source it comes from, which row of that source
# and which column.
Kroot, Kcpudir, Kmemdir, Kcpu, Kmem, Ktop, Klog: con iota;

PATH(kind, idx, fld: int): big
{
	return (big kind << 32) | (big idx << 8) | big fld;
}
KIND(p: big): int	{ return int (p >> 32); }
IDX(p: big): int	{ return int ((p >> 8) & big 16rffffff); }
FLD(p: big): int	{ return int (p & big 16rff); }

# Column names, in the order the kernel writes them.  A name here is a
# promise about a column there; if devcons.c's sysstat loop changes,
# this list is what has to change with it.
cpufields := array[] of {
	"cs", "intr", "syscall", "pfault", "tlbfault", "tlbpurge",
	"load", "idle"
};
memfields := array[] of {
	"used", "max", "highwater", "nalloc", "nfree", "nbrk", "largest"
};
# Top-level scalars, each with the file it needs.  A leaf is created
# only if its source can be opened, because a metrics tree that answers
# 0 for something it cannot measure is worse than one that does not
# offer the file: the zero is indistinguishable from a real reading.
# emu has no /dev/osversion and no /dev/sysstat, so under emu this tree
# simply has fewer files than it does on a kernel.
topfields := array[] of {
	"uptime", "time", "osversion", "procs", "sysname"
};
topsource := array[] of {
	"", "/dev/time", "/dev/osversion", "/prog", "/dev/sysname"
};

cpunames: list of string;
memnames: list of string;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil)
		fail(sys->sprint("cannot load %s: %r", Styx->PATH));
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		fail(sys->sprint("cannot load %s: %r", Styxservers->PATH));
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		fail(sys->sprint("cannot load %s: %r", Nametree->PATH));
	nametree->init();

	navop: chan of ref Styxservers->Navop;
	tree: ref Tree;
	(tree, navop) = nametree->start();
	nav := Navigator.new(navop);
	(tchan, srv) := Styxserver.new(sys->fildes(0), nav, PATH(Kroot,0,0));

	tree.create(PATH(Kroot,0,0), dir(".", Sys->DMDIR|8r555, PATH(Kroot,0,0)));
	for(i := 0; i < len topfields; i++){
		src := topsource[i];
		if(src == "")			# uptime: either source will do
			src = uptimesource();
		if(src == "" || !have(src))
			continue;
		tree.create(PATH(Kroot,0,0), dir(topfields[i], 8r444, PATH(Ktop,0,i)));
	}
	if(have("/dev/kmesg"))
		tree.create(PATH(Kroot,0,0), dir("log", 8r444, PATH(Klog,0,0)));

	# The shape of the tree is fixed at start from what the machine has
	# now: one directory per processor the kernel is running on and one
	# per memory pool.  A processor that comes up later does not appear
	# until this is restarted, which is a real limitation and is in the
	# man page rather than hidden.
	cpunames = rows("/dev/sysstat", 0);
	n := 0;
	if(cpunames != nil)
		tree.create(PATH(Kroot,0,0), dir("cpu", Sys->DMDIR|8r555, PATH(Kcpudir,0,0)));
	for(l := cpunames; l != nil; l = tl l){
		tree.create(PATH(Kcpudir,0,0), dir(hd l, Sys->DMDIR|8r555, PATH(Kcpudir,n+1,0)));
		for(i = 0; i < len cpufields; i++)
			tree.create(PATH(Kcpudir,n+1,0),
				dir(cpufields[i], 8r444, PATH(Kcpu,n,i)));
		n++;
	}

	memnames = rows("/dev/memory", 7);
	n = 0;
	if(memnames != nil)
		tree.create(PATH(Kroot,0,0), dir("mem", Sys->DMDIR|8r555, PATH(Kmemdir,0,0)));
	for(l = memnames; l != nil; l = tl l){
		tree.create(PATH(Kmemdir,0,0), dir(hd l, Sys->DMDIR|8r555, PATH(Kmemdir,n+1,0)));
		for(i = 0; i < len memfields; i++)
			tree.create(PATH(Kmemdir,n+1,0),
				dir(memfields[i], 8r444, PATH(Kmem,n,i)));
		n++;
	}

	for(;;){
		gm := <-tchan;
		if(gm == nil){
			tree.quit();
			exit;
		}
		pick m := gm {
		Read =>
			f := srv.getfid(m.fid);
			if(f == nil || (f.qtype & Sys->QTDIR)){
				srv.default(gm);
				continue;
			}
			srv.reply(styxservers->readbytes(m,
				array of byte value(f.path)));
		* =>
			srv.default(gm);
		}
	}
}

# The value of one leaf, read now.
value(path: big): string
{
	case KIND(path) {
	Ktop =>
		case FLD(path) {
		0 =>	return uptime();
		1 =>	return field(readfile("/dev/time"), 0) + "\n";
		2 =>	return trim(readfile("/dev/osversion")) + "\n";
		3 =>	return string nprogs() + "\n";
		4 =>	s := trim(readfile("/dev/sysname"));
			if(s == nil)
				s = "unnamed";
			return s + "\n";
		}
		return "\n";
	Kcpu =>
		# column 0 of sysstat is the processor number, so the named
		# fields start at 1.
		return field(row("/dev/sysstat", IDX(path)), FLD(path)+1) + "\n";
	Kmem =>
		return field(row("/dev/memory", IDX(path)), FLD(path)) + "\n";
	Klog =>
		return readfile("/dev/kmesg");
	}
	return "\n";
}

# Seconds since boot.  A native kernel's /dev/time is Plan 9's four
# fields and the last two are ticks and ticks per second; emu's is a
# single microsecond count of the wall clock, which says nothing about
# when this machine started, so there /dev/msec is the source.  Neither
# is guessed: uptimesource() picks whichever exists and the file is not
# created if neither does.
uptimesource(): string
{
	(nf, nil) := sys->tokenize(readfile("/dev/time"), " \t\n");
	if(nf >= 4)
		return "/dev/time";
	# The value, not just the file.  emu serves /dev/msec and it reads
	# 0 forever there, so testing that the file opens would offer an
	# uptime that is always zero -- the dishonesty this tree is trying
	# to avoid.  A machine that really has just started reads 0 for a
	# millisecond and then does not.
	if(have("/dev/msec") && int trim(readfile("/dev/msec")) > 0)
		return "/dev/msec";
	return "";
}

uptime(): string
{
	case uptimesource() {
	"/dev/time" =>
		(nf, flds) := sys->tokenize(readfile("/dev/time"), " \t\n");
		if(nf < 4)
			return "0\n";
		flds = tl tl flds;
		ticks := big hd flds;
		hz := big hd tl flds;
		if(hz == big 0)
			return "0\n";
		return string (ticks / hz) + "\n";
	"/dev/msec" =>
		return string ((big trim(readfile("/dev/msec"))) / big 1000) + "\n";
	}
	return "0\n";
}

have(f: string): int
{
	return sys->open(f, Sys->OREAD) != nil;
}

nprogs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return 0;
	n := 0;
	for(;;){
		(nd, nil) := sys->dirread(fd);
		if(nd <= 0)
			break;
		n += nd;
	}
	return n;
}

# The nth line of a file, or nil.
row(file: string, n: int): string
{
	(nil, lines) := sys->tokenize(readfile(file), "\n");
	for(; lines != nil; lines = tl lines){
		if(n == 0)
			return hd lines;
		n--;
	}
	return nil;
}

# One whitespace-separated field of a line.
field(line: string, n: int): string
{
	(nf, flds) := sys->tokenize(line, " \t");
	if(n >= nf)
		return "0";
	for(; n > 0; n--)
		flds = tl flds;
	return hd flds;
}

# Directory names for the rows of a source file.  namefld < 0 means the
# rows have no name of their own and are numbered.
rows(file: string, namefld: int): list of string
{
	r: list of string;
	(nil, lines) := sys->tokenize(readfile(file), "\n");
	i := 0;
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(trim(l) == nil)
			continue;
		if(namefld > 0)
			r = field(l, namefld) :: r;
		else
			r = field(l, 0) :: r;	# sysstat names by machno
		i++;
	}
	return rev(r);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

trim(s: string): string
{
	while(s != nil && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n'))
		s = s[1:];
	while(s != nil && (s[len s - 1] == ' ' || s[len s - 1] == '\t'
			|| s[len s - 1] == '\n'))
		s = s[0:len s - 1];
	return s;
}

dir(name: string, perm: int, path: big): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "metric";
	d.gid = "metric";
	d.qid.path = path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "metricfs: %s\n", s);
	raise "fail:" + s;
}
