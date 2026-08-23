implement Command;

#
# Compare recorded Dis schedules.
#
# A schedule comes from INFERNO_SCHED_RECORD (see emu(1)). Comparing two of
# them answers the question that decides whether forcing a schedule on a later
# run is worth anything: how much do two runs of the same session actually
# differ?
#
# The answer is not one number, which is why this reports several. Filtering
# iyield out matters more than anything else here: a yield is a vmachine kproc
# handing the slot to a proc already waiting for it, which is host-thread
# bookkeeping and changes nothing about which Dis program runs when. Left in,
# it swamps the comparison; taken out, a sequential session turns out to be
# exactly reproducible.
#
include "sys.m";
	sys: Sys;
	print, fprint, sprint: import sys;
include "draw.m";
include "arg.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Hdrsz:	con 12;
Recsz:	con 9;

Ev: adt {
	kind:	int;
	pid:	int;
	hash:	int;
};

Sched: adt {
	path:	string;
	cflag:	int;
	ev:	array of Ev;
};

usage()
{
	fprint(sys->fildes(2), "usage: schedcmp [-v] file1 file2 [file3...]\n");
	raise "fail:usage";
}

g32b(b: array of byte, o: int): int
{
	return (int b[o]<<24) | (int b[o+1]<<16) | (int b[o+2]<<8) | int b[o+3];
}

readsched(path: string): ref Sched
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		fprint(sys->fildes(2), "schedcmp: %s: %r\n", path);
		raise "fail:open";
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		raise "fail:stat";
	buf := array[int d.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf){
		fprint(sys->fildes(2), "schedcmp: short read of %s\n", path);
		raise "fail:read";
	}
	if(len buf < Hdrsz || string buf[0:8] != "infsched"){
		fprint(sys->fildes(2), "schedcmp: %s is not a schedule\n", path);
		raise "fail:magic";
	}
	s := ref Sched;
	s.path = path;
	s.cflag = g32b(buf, 8);
	n := (len buf - Hdrsz) / Recsz;
	s.ev = array[n] of Ev;
	for(i := 0; i < n; i++){
		o := Hdrsz + i*Recsz;
		s.ev[i].kind = int buf[o];
		s.ev[i].pid = g32b(buf, o+1);
		s.ev[i].hash = g32b(buf, o+5);
	}
	return s;
}

# the events of one schedule that a filter keeps
select(s: ref Sched, drop: string, only: string): array of Ev
{
	n := 0;
	for(i := 0; i < len s.ev; i++)
		if(keep(s.ev[i], drop, only))
			n++;
	r := array[n] of Ev;
	n = 0;
	for(i = 0; i < len s.ev; i++)
		if(keep(s.ev[i], drop, only))
			r[n++] = s.ev[i];
	return r;
}

# drop and only are sets of event kinds, as strings: "y", "ar", or nil
keep(e: Ev, drop: string, only: string): int
{
	for(i := 0; i < len drop; i++)
		if(e.kind == int drop[i])
			return 0;
	if(only == nil)
		return 1;
	for(i = 0; i < len only; i++)
		if(e.kind == int only[i])
			return 1;
	return 0;
}

same(a, b: Ev, pidonly: int): int
{
	if(a.pid != b.pid)
		return 0;
	if(pidonly)
		return 1;
	return a.kind == b.kind && a.hash == b.hash;
}

compare(what: string, ss: list of ref Sched, drop: string, only: string, pidonly: int)
{
	sel: list of array of Ev;
	shortest := -1;
	lens := "";
	for(l := ss; l != nil; l = tl l){
		e := select(hd l, drop, only);
		sel = e :: sel;
		if(shortest < 0 || len e < shortest)
			shortest = len e;
		lens += sprint(" %d", len e);
	}

	# common prefix across every schedule, and whether all are equal
	pref := shortest;
	for(i := 0; i < shortest; i++){
		ok := 1;
		first: Ev;
		n := 0;
		for(m := sel; m != nil; m = tl m){
			e := (hd m)[i];
			if(n++ == 0)
				first = e;
			else if(!same(first, e, pidonly))
				ok = 0;
		}
		if(!ok){
			pref = i;
			break;
		}
	}
	allsame := pref == shortest;
	for(m := sel; m != nil; m = tl m)
		if(len hd m != shortest)
			allsame = 0;
	verdict := "no";
	if(allsame)
		verdict = "YES";
	print("%-30s lengths%-24s identical=%-4s common prefix=%d\n",
		what, lens, verdict, pref);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		print("schedcmp: load: %r\n");
		raise "fail:load";
	}
	verbose := 0;
	arg->init(argv);
	arg->setusage("schedcmp [-v] file1 file2 [file3...]");
	while((o := arg->opt()) != 0)
		case o {
		'v' =>	verbose++;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil || tl argv == nil)
		usage();

	ss: list of ref Sched;
	cflag := -1;
	for(l := argv; l != nil; l = tl l){
		s := readsched(hd l);
		# the JIT and the interpreter reach system calls at different
		# points, so comparing across them measures nothing
		if(cflag < 0)
			cflag = s.cflag;
		else if(s.cflag != cflag){
			fprint(sys->fildes(2), "schedcmp: %s was recorded under -c%d, the first under -c%d; these cannot be compared\n", s.path, s.cflag, cflag);
			raise "fail:cflag";
		}
		ss = s :: ss;
	}

	if(verbose){
		for(m := ss; m != nil; m = tl m){
			s := hd m;
			(q, a, r, y) := (0, 0, 0, 0);
			for(i := 0; i < len s.ev; i++)
				case s.ev[i].kind {
				'q' =>	q++;
				'a' =>	a++;
				'r' =>	r++;
				'y' =>	y++;
				}
			print("%s: %d events, -c%d, q=%d a=%d r=%d y=%d\n",
				s.path, len s.ev, s.cflag, q, a, r, y);
		}
	}

	compare("all events",               ss, nil, nil,  0);
	compare("without iyield",           ss, "y", nil,  0);
	compare("quanta only",              ss, nil, "q",  0);
	compare("host-call boundaries",     ss, nil, "ar", 0);
	compare("pid order, without iyield", ss, "y", nil, 1);
}
