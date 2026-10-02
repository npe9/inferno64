implement Vmsched;

#
# vmsched -- place Linux guests across hypervisor hosts and run them
# (doc/genesize-plan.ms, phase 11).
#
#	vmsched [-n guests] [-m megabytes] [-i initrd] [-s seconds] kernel hostdir ...
#
# Each hostdir is a hypervisor host's namespace mounted here (its #H in
# hostdir/dev/vm), typically over Styx.  vmsched reads each host's
# dev/vm/host -- processors, free memory, the largest contiguous run of
# it, machines already running -- and places the guests: on the host
# running the fewest machines, ties to the one with the most contiguous
# memory, never on one whose largest run is smaller than the guest.
# Placement is policy here, in Limbo; the hosts only report and obey.
#
# Each guest is then run by vmlinux(1) in a namespace of its own with
# its host's /dev bound in, so vmlinux makes the machine there; the
# guests run at once.  Each is typed a line naming it and the host it
# was placed on once its shell is up, and stops when it answers.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "sh.m";

Vmsched: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Host: adt {
	dir:	string;
	memlargest:	big;
	machines:	int;
	placed:	int;
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("load %s: %r", Arg->PATH));
	arg->init(argv);
	n := 2;
	megs := 256;
	initrd := "";
	secs := "1200";
	while((c := arg->opt()) != 0)
		case c {
		'n' =>	n = int arg->earg();
		'm' =>	megs = int arg->earg();
		'i' =>	initrd = arg->earg();
		's' =>	secs = arg->earg();
		* =>	usage();
		}
	argv = arg->argv();
	if(len argv < 2)
		usage();
	kernel := hd argv;
	argv = tl argv;

	hosts: list of ref Host;
	for(; argv != nil; argv = tl argv){
		h := ref Host(hd argv, big 0, 0, 0);
		info := readfile(h.dir + "/dev/vm/host");
		if(info == nil){
			sys->fprint(stderr, "vmsched: %s: no dev/vm/host: %r\n", h.dir);
			continue;
		}
		h.memlargest = big field(info, "memlargest");
		h.machines = int field(info, "machines");
		if(field(info, "backend") == "none"){
			sys->print("vmsched: %s: no hypervisor backend; not used\n", h.dir);
			continue;
		}
		sys->print("vmsched: host %s: %s", h.dir, info);
		hosts = h :: hosts;
	}
	if(hosts == nil)
		fail("no usable host");

	need := big megs * big (1024*1024);
	done := chan of string;
	nplaced := 0;
	for(g := 0; g < n; g++){
		h := place(hosts, need);
		if(h == nil){
			sys->print("vmsched: guest %d: no host has %d MiB contiguous\n", g, megs);
			continue;
		}
		h.placed++;
		h.memlargest -= need;
		sys->print("vmsched: guest %d -> %s\n", g, h.dir);
		spawn run(g, h.dir, kernel, initrd, megs, secs, done);
		nplaced++;
	}
	for(nrun := 0; nrun < nplaced; nrun++){
		s := <-done;
		sys->print("vmsched: %s\n", s);
	}
	for(l := hosts; l != nil; l = tl l)
		sys->print("vmsched: host %s now: %s", (hd l).dir, readfile((hd l).dir + "/dev/vm/host"));
}

# fewest machines (running and placed), then most contiguous memory
place(hosts: list of ref Host, need: big): ref Host
{
	best: ref Host;
	for(l := hosts; l != nil; l = tl l){
		h := hd l;
		if(h.memlargest < need)
			continue;
		if(best == nil
		|| h.machines + h.placed < best.machines + best.placed
		|| h.machines + h.placed == best.machines + best.placed && h.memlargest > best.memlargest)
			best = h;
	}
	return best;
}

run(g: int, dir, kernel, initrd: string, megs: int, secs: string, done: chan of string)
{
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind(dir + "/dev", "/dev", Sys->MAFTER) < 0){
		done <-= sys->sprint("guest %d on %s: bind: %r", g, dir);
		return;
	}
	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		done <-= sys->sprint("guest %d on %s: load vmlinux: %r", g, dir);
		return;
	}
	args := "vmlinux" :: "-s" :: secs :: "-m" :: string megs :: "-q" :: "LINUXGUEST: ran" :: nil;
	if(initrd != "")
		args = append(args, "-i" :: initrd :: nil);
	args = append(args, "-t" :: sys->sprint("echo LINUXGUEST: guest %d placed on %s; uname -sr; echo LINUXGUEST: \"r\"an", g, dir) :: kernel :: nil);
	{
		vmlinux->init(nil, args);
		done <-= sys->sprint("guest %d on %s: finished", g, dir);
	} exception e {
	"*" =>
		done <-= sys->sprint("guest %d on %s: %s", g, dir, e);
	}
}

append(a, b: list of string): list of string
{
	if(a == nil)
		return b;
	return hd a :: append(tl a, b);
}

field(s, name: string): string
{
	(nil, l) := sys->tokenize(s, " \n");
	for(; l != nil; l = tl l)
		if(hd l == name && tl l != nil)
			return hd tl l;
	return "0";
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[1024] of byte;
	s := "";
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

usage()
{
	sys->fprint(stderr, "usage: vmsched [-n guests] [-m megabytes] [-i initrd] [-s seconds] kernel hostdir ...\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(stderr, "vmsched: %s\n", s);
	raise "fail:" + s;
}
