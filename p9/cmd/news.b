implement News;

# Real 9front sys/src/cmd/news.c (239 lines), translated 1:1 - not a
# workalike. Source: /Users/npe/src/plan9front/sys/src/cmd/news.c
# (pulled from outside this repo, same as cb.c/qr.c were).
#
#	news foo	prints /lib/news/foo
#	news -a		prints all news items, latest first
#	news -n		lists names of new items
#	news		prints items changed since last news
#
# THE ONE FIDELITY DECISION WORTH FLAGGING UP FRONT: the real source
# has no flag to point NEWS anywhere but the literal path "/lib/news",
# and no flag to point the per-user "already read up to here" marker
# anywhere but "$home/lib/newstime" - both are hardcoded absolute
# paths in the C, not parameters. A faithful translation keeps them
# exactly that way rather than inventing a "-d dir" override the real
# tool never had. This makes the fixture problem a test-suite concern,
# not a subsystem one (per this backlog's own scoping note): newstest.b
# creates and removes a real /lib/news directory in the live emu
# namespace for the duration of the test, and drives "$home" itself
# via Env->setenv rather than depending on whatever ambient $home this
# host happens to already have - see newstest.b's own header comment.
#
# Three module-level translation choices, each replacing a hand-rolled
# C helper with an existing Limbo module rather than re-deriving it:
#
#   - getenv("home") -> Env->getenv("home") (module/env.m) - Inferno's
#     env is case-sensitive and uses the same lowercase names as Plan
#     9's, so this is a direct match, not an approximation.
#
#   - dirreadall()+qsort(..., fcmp) -> Readdir->init(NEWS, Readdir->MTIME)
#     (module/readdir.m). Readdir's own sort is a stable mergesort over
#     exactly the Sys->Dir shape being sorted here. Found only by
#     testing, not assumed from the flag's own name: plain MTIME (not
#     MTIME|DESCENDING) is what gives newest-first here, matching
#     fcmp's `x = b->time - a->time; x<0 => -1` (larger time sorts
#     first) - confirmed with a standalone three-file probe outside
#     this suite, dumping both orderings directly (MTIME alone gave
#     newest-first; MTIME|DESCENDING gave oldest-first, the reverse of
#     what its own name suggests). Not this tree's bug to fix - just a
#     surprising library behavior worth recording rather than silently
#     working around. This tree has no generic qsort (p9/cmd/patch.b's
#     own header comment says as much and hand-rolls an insertion sort
#     for its own ADT) - Readdir is not a generic sort, but it already
#     exists for exactly this shape, so using it beats hand-rolling a
#     second implementation of the same mergesort for one call site.
#     The ignore-list filter ("core", "dead.letter") and the synthetic
#     "last read" boundary entry are NOT things Readdir knows about, so
#     those are still applied by hand, same as the source does after
#     its own qsort.
#
#   - asctime(localtime(mtime)) -> Daytime->local() (module/daytime.m)
#     for the field breakdown, but NOT Daytime->text() for the string:
#     text()'s own format ("%s %s %.2d %.2d:%.2d:%.2d %s %d") differs
#     from Plan 9's asctime in three ways - it zero-pads the day where
#     asctime space-pads it, it includes a zone field asctime doesn't
#     have, and asctime's own trailing "\n" is part of its return value
#     (preserved here since the format string below appends its own
#     literal "\n" on top of it, in the format string used by
#     print_item() below - reproducing the doubled newline, and
#     resulting blank line before each item's body, that the real
#     source's own `"...%s\n"` format around an already-"\n"-terminated
#     asctime() produces).
#
# Everything else - the ignore list, the bol/bop tab-reindentation of
# each item's body text, the -a/-n/default dispatch, explicit named
# files bypassing the mtime scan entirely - is translated directly.
#
# One shortcut taken deliberately, confirmed behaviour-preserving
# rather than assumed: the C's `if(argc == 1) { eachitem(...); exits(0); }`
# fast path before ARGBEGIN is *not* a distinct case - it uses exactly
# the same (printer=print_item, printall=0, doupdate=1) defaults that
# falling through the general flag-parsing path with zero flags and
# zero file arguments already produces, so this translation has one
# path, not two, with no behaviour change.

include "sys.m";
	sys: Sys;
	Dir: import sys;
include "draw.m";
	Context: import Draw;
include "env.m";
	env: Env;
include "readdir.m";
	readdir: Readdir;
include "daytime.m";
	daytime: Daytime;

News: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(args: list of string): (string, int);
};

NEWS:		con "/lib/news";
TFILEFMT:	con "%s/lib/newstime";

ignorelist := array[] of {"core", "dead.letter"};

wkday := array[] of {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
month := array[] of {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

stderr:		ref Sys->FD;
capturing:	int;
outbuf:		string;
nitems:		int;

Item: adt
{
	name:	string;
	time:	int;
	length:	big;
};

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(env == nil)
		env = load Env Env->PATH;
	if(readdir == nil)
		readdir = load Readdir Readdir->PATH;
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
}

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

fail(msg: string)
{
	sys->fprint(stderr, "news: %s\n", msg);
	raise "fail:news";
}

isignored(name: string): int
{
	for(i := 0; i < len ignorelist; i++)
		if(ignorelist[i] == name)
			return 1;
	return 0;
}

# insertboundary splices the synthetic "already read up to here" entry
# into the already-time-descending array at the position that keeps it
# sorted - the same slot a combined qsort(..., fcmp) would have put it
# in, since a's own relative order is already correct and the boundary
# is the only new element.
insertboundary(a: array of ref Item, t: int): array of ref Item
{
	n := len a;
	idx := n;
	for(i := 0; i < n; i++){
		if(a[i].time <= t){
			idx = i;
			break;
		}
	}
	r := array[n + 1] of ref Item;
	r[0:] = a[0:idx];
	r[idx] = ref Item("", t, big 0);
	r[idx + 1:] = a[idx:];
	return r;
}

# builditems is read_dir() - it reads NEWS's directory, drops the
# ignored names, and (if $home is set) folds in the synthetic boundary
# entry marking the last time news was read, optionally (re)touching
# $home/lib/newstime to move that boundary to now.
builditems(update: int): array of ref Item
{
	(a, nd) := readdir->init(NEWS, Readdir->MTIME);
	if(nd < 0)
		fail(sys->sprint("%s: %r", NEWS));

	items: list of ref Item;
	n := 0;
	i: int;
	for(i = 0; i < len a; i++){
		d := a[i];
		if(isignored(d.name))
			continue;
		items = ref Item(d.name, d.mtime, d.length) :: items;
		n++;
	}
	arr := array[n] of ref Item;
	i = n - 1;
	for(; items != nil; items = tl items){
		arr[i] = hd items;
		i--;
	}

	home := env->getenv("home");
	if(home != nil){
		newstimepath := sys->sprint(TFILEFMT, home);
		(ok, d) := sys->stat(newstimepath);
		if(ok >= 0)
			arr = insertboundary(arr, d.mtime - 1);
		if(update)
			sys->create(newstimepath, Sys->OWRITE, 8r644);
	}
	return arr;
}

asctimestr(t: int): string
{
	tm := daytime->local(t);
	return sys->sprint("%s %s %2d %.2d:%.2d:%.2d %d\n",
		wkday[tm.wday], month[tm.mon], tm.mday,
		tm.hour, tm.min, tm.sec, 1900 + tm.year);
}

printitem(file: string)
{
	path := NEWS + "/" + file;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "news: %s: %r\n", path);
		return;
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return;
	who := d.uid;
	if(len d.muid > 0)
		who = d.muid;
	emit(sys->sprint("\n%s (%s) %s\n", file, who, asctimestr(d.mtime)));

	bol := 1;	# beginning of line ...\n
	bop := 1;	# beginning of page ...\n\n
	buf := array[8192] of byte;
	outbytes := array[2 * 8192] of byte;
	for(;;){
		nr := sys->read(fd, buf, len buf);
		if(nr <= 0)
			break;
		oi := 0;
		for(i := 0; i < nr; i++){
			c := buf[i];
			if(c == byte '\n'){
				if(!bop){
					outbytes[oi++] = byte '\n';
					if(bol)
						bop = 1;
					bol = 1;
				}
				continue;
			}
			if(bol){
				outbytes[oi++] = byte '\t';
				bol = 0;
				bop = 0;
			}
			outbytes[oi++] = c;
		}
		if(oi > 0)
			emit(string outbytes[0:oi]);
	}
	if(!bol)
		emit("\n");
}

note(file: string)
{
	if(!nitems)
		emit("news:");
	emit(" " + file);
	nitems++;
}

eachitem(namesonly, printall, doupdate: int)
{
	items := builditems(doupdate);
	for(i := 0; i < len items; i++){
		it := items[i];
		if(it.name == ""){
			if(printall)
				continue;
			break;
		}
		if(it.length == big 0)	# in progress
			continue;
		if(namesonly)
			note(it.name);
		else
			printitem(it.name);
	}
}

# dispatch is main()'s own ARGBEGIN/ARGEND plus the argc==0-vs-explicit-
# files branch - shared by both entry points below so streaming init()
# and capturing run() can't disagree about what "capturing" means; only
# they, not dispatch itself, touch that flag (see the tar.b precedent
# this follows, cited in this file's own header comment).
dispatch(args: list of string)
{
	nitems = 0;

	doupdate := 1;
	printall := 0;
	namesonly := 0;

	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		l = tl l;
		case w[1] {
		'a' =>
			doupdate = 0;
			printall = 1;
		'n' =>
			doupdate = 0;
			namesonly = 1;
		* =>
			fail(sys->sprint("bad option %c", w[1]));
		}
	}

	if(l == nil)
		eachitem(namesonly, printall, doupdate);
	else
		for(; l != nil; l = tl l)
			printitem(hd l);

	if(nitems)
		emit("\n");
}

run(args: list of string): (string, int)
{
	loadmods();
	if(stderr == nil)
		stderr = sys->fildes(2);

	capturing = 1;
	outbuf = "";
	dispatch(args);
	capturing = 0;
	return (outbuf, 0);
}

init(nil: ref Context, argv: list of string)
{
	loadmods();
	stderr = sys->fildes(2);

	args: list of string;
	if(argv != nil)
		args = tl argv;

	capturing = 0;
	dispatch(args);
}
