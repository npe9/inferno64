implement Command;

#
# Check that styxlog(1) names fids correctly.
#
# A trace is messages about numbered fids; a walk is what gives a fid its
# meaning. Following those is the whole of what styxlog does, and the way to
# get it wrong is subtle enough to have happened: a single slot for the walk
# in flight is right for one process and silently wrong for two, because their
# walks interleave and one process's reply then takes the other's path. The
# output stays entirely plausible, which is why nothing noticed.
#
# So the interesting cases are all about concurrency, and none of them can be
# produced by tracing a single program. The trace is a documented format, so
# this builds one - the same reason sessiontest(1) builds recordings.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "string.m";
	str: String;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Logger: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

failed := 0;
trace := "/styxtest.trace";
out := "/styxtest.out";

# one record of a trace: direction, time in microseconds, then the message
Rec: adt {
	dir:	int;
	at:	int;
	msg:	array of byte;
};

pbe32(b: array of byte, o, v: int)
{
	b[o] = byte (v>>24);
	b[o+1] = byte (v>>16);
	b[o+2] = byte (v>>8);
	b[o+3] = byte v;
}

pbe64(b: array of byte, o: int, v: big)
{
	for(i := 0; i < 8; i++)
		b[o+i] = byte int ((v >> ((7-i)*8)) & big 16rff);
}

write(recs: array of Rec): string
{
	n := 0;
	for(i := 0; i < len recs; i++)
		n += 13 + len recs[i].msg;
	buf := array[n] of byte;
	o := 0;
	for(i = 0; i < len recs; i++){
		buf[o] = byte recs[i].dir;
		pbe64(buf, o+1, big recs[i].at);
		pbe32(buf, o+9, len recs[i].msg);
		buf[o+13:] = recs[i].msg;
		o += 13 + len recs[i].msg;
	}
	fd := sys->create(trace, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sprint("cannot create %s: %r", trace);
	if(sys->write(fd, buf, len buf) != len buf)
		return sprint("cannot write %s: %r", trace);
	return nil;
}

qid(path: int): Sys->Qid
{
	return Sys->Qid(big path, 0, Sys->QTFILE);
}

qids(n: int): array of Sys->Qid
{
	q := array[n] of Sys->Qid;
	for(i := 0; i < n; i++)
		q[i] = qid(100+i);
	return q;
}

T(at: int, m: ref Tmsg): Rec
{
	return Rec('T', at, m.pack());
}

R(at: int, m: ref Rmsg): Rec
{
	return Rec('R', at, m.pack());
}

# run styxlog over the trace with its output captured, and give back the lines
run(): (list of string, string)
{
	logger := load Logger "/dis/styxlog.dis";
	if(logger == nil)
		return (nil, sprint("cannot load /dis/styxlog.dis: %r"));
	ofd := sys->create(out, Sys->OWRITE, 8r666);
	if(ofd == nil)
		return (nil, sprint("cannot create %s: %r", out));

	# keep our own standard output, since everything below reports through it
	saved := sys->dup(1, -1);
	sys->dup(ofd.fd, 1);
	{
		logger->init(nil, "styxlog" :: trace :: nil);
	}exception{
	"fail:*" =>
		;
	* =>
		;
	}
	sys->dup(saved, 1);
	ofd = nil;

	fd := sys->open(out, Sys->OREAD);
	if(fd == nil)
		return (nil, sprint("cannot read %s: %r", out));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, "cannot stat the output");
	buf := array[int d.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		return (nil, "short read of the output");
	lines: list of string;
	n := 0;
	for(i := 0; i < len buf; ){
		j := i;
		while(j < len buf && buf[j] != byte '\n')
			j++;
		l := string buf[i:j];
		i = j+1;
		if(l != nil)
			lines = l :: lines;
		n++;
	}
	r: list of string;
	for(; lines != nil; lines = tl lines)
		r = hd lines :: r;
	return (r, nil);
}

# the paths styxlog reported opening, in order
opens(lines: list of string): list of string
{
	r: list of string;
	for(l := lines; l != nil; l = tl l){
		(n, f) := sys->tokenize(hd l, " \t");
		if(n >= 3 && hd tl f == "open"){
			# everything after the verb, because an unnamed fid is
			# written "<fid 1>" and has a space in it
			p := "";
			for(g := tl tl f; g != nil; g = tl g){
				if(p != "")
					p += " ";
				p += hd g;
			}
			r = p :: r;
		}
	}
	q: list of string;
	for(; r != nil; r = tl r)
		q = hd r :: q;
	return q;
}

check(what: string, recs: array of Rec, want: list of string)
{
	if((e := write(recs)) != nil){
		print("FAIL %s: %s\n", what, e);
		failed++;
		return;
	}
	(lines, err) := run();
	if(err != nil){
		print("FAIL %s: %s\n", what, err);
		failed++;
		return;
	}
	got := opens(lines);
	ok := len got == len want;
	if(ok){
		g := got;
		w := want;
		while(g != nil){
			if(hd g != hd w)
				ok = 0;
			g = tl g;
			w = tl w;
		}
	}
	if(ok){
		print("ok   %s\n", what);
		return;
	}
	print("FAIL %s\n", what);
	print("     wanted opens:");
	for(l := want; l != nil; l = tl l)
		print(" %s", hd l);
	print("\n     got opens:   ");
	for(l = got; l != nil; l = tl l)
		print(" %s", hd l);
	print("\n");
	failed++;
}

# the messages every trace starts with
preamble(): list of Rec
{
	return R(30, ref Rmsg.Attach(1, qid(1))) ::
		T(20, ref Tmsg.Attach(1, 0, -1, "eve", "")) ::
		R(10, ref Rmsg.Version(0, 8192, "9P2000")) ::
		T(0, ref Tmsg.Version(0, 8192, "9P2000")) :: nil;
}

cat(a: list of Rec, b: array of Rec): array of Rec
{
	n := len a + len b;
	r := array[n] of Rec;
	i := len a - 1;
	for(l := a; l != nil; l = tl l)
		r[i--] = hd l;
	for(j := 0; j < len b; j++)
		r[len a + j] = b[j];
	return r;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	str = load String String->PATH;
	if(styx == nil){
		print("styxtest: cannot load %s: %r\n", Styx->PATH);
		raise "fail:load";
	}
	styx->init();

	# one process, one walk at a time: the case that always worked
	check("a single walk names its fid",
		cat(preamble(), array[] of {
			T(100, ref Tmsg.Walk(2, 0, 1, array[] of {"dis", "echo.dis"})),
			R(110, ref Rmsg.Walk(2, qids(2))),
			T(120, ref Tmsg.Open(3, 1, Sys->OREAD)),
			R(130, ref Rmsg.Open(3, qid(100), 8192)),
		}),
		list of {"/dis/echo.dis"});

	# two processes walking at once, replies in order. A single slot for the
	# walk in flight gives the first reply the second's path.
	check("interleaved walks keep their own paths",
		cat(preamble(), array[] of {
			T(100, ref Tmsg.Walk(2, 0, 1, array[] of {"dis", "echo.dis"})),
			T(105, ref Tmsg.Walk(3, 0, 2, array[] of {"dev", "null"})),
			R(110, ref Rmsg.Walk(2, qids(2))),
			R(115, ref Rmsg.Walk(3, qids(2))),
			T(120, ref Tmsg.Open(4, 1, Sys->OREAD)),
			R(125, ref Rmsg.Open(4, qid(100), 8192)),
			T(130, ref Tmsg.Open(5, 2, Sys->OWRITE)),
			R(135, ref Rmsg.Open(5, qid(101), 8192)),
		}),
		list of {"/dis/echo.dis", "/dev/null"});

	# and with the replies out of order, which is the case a slot cannot
	# get right by luck
	check("interleaved walks answered in the other order",
		cat(preamble(), array[] of {
			T(100, ref Tmsg.Walk(2, 0, 1, array[] of {"dis", "echo.dis"})),
			T(105, ref Tmsg.Walk(3, 0, 2, array[] of {"dev", "null"})),
			R(110, ref Rmsg.Walk(3, qids(2))),
			R(115, ref Rmsg.Walk(2, qids(2))),
			T(120, ref Tmsg.Open(4, 1, Sys->OREAD)),
			R(125, ref Rmsg.Open(4, qid(100), 8192)),
			T(130, ref Tmsg.Open(5, 2, Sys->OWRITE)),
			R(135, ref Rmsg.Open(5, qid(101), 8192)),
		}),
		list of {"/dis/echo.dis", "/dev/null"});

	# a walk that stopped early never established the new fid, so naming it
	# would invent a path deeper than it is
	check("a short walk does not name the fid",
		cat(preamble(), array[] of {
			T(100, ref Tmsg.Walk(2, 0, 1, array[] of {"dis", "nowhere.dis"})),
			R(110, ref Rmsg.Walk(2, qids(1))),	# one qid for two names
			T(120, ref Tmsg.Open(3, 1, Sys->OREAD)),
			R(130, ref Rmsg.Open(3, qid(100), 8192)),
		}),
		list of {"<fid 1>"});

	# a walk that failed outright must not name it either
	check("a failed walk does not name the fid",
		cat(preamble(), array[] of {
			T(100, ref Tmsg.Walk(2, 0, 1, array[] of {"dis", "nowhere.dis"})),
			R(110, ref Rmsg.Error(2, "does not exist")),
			T(120, ref Tmsg.Open(3, 1, Sys->OREAD)),
			R(130, ref Rmsg.Open(3, qid(100), 8192)),
		}),
		list of {"<fid 1>"});

	# a clunked fid is forgotten, so a later fid of the same number is not
	# given the old name
	check("a clunked fid is forgotten",
		cat(preamble(), array[] of {
			T(100, ref Tmsg.Walk(2, 0, 1, array[] of {"dis", "echo.dis"})),
			R(110, ref Rmsg.Walk(2, qids(2))),
			T(120, ref Tmsg.Clunk(3, 1)),
			R(125, ref Rmsg.Clunk(3)),
			T(130, ref Tmsg.Open(4, 1, Sys->OREAD)),
			R(135, ref Rmsg.Open(4, qid(100), 8192)),
		}),
		list of {"<fid 1>"});

	sys->remove(trace);
	sys->remove(out);
	if(failed){
		print("styxtest: %d checks failed\n", failed);
		raise "fail:test";
	}
	print("PASS\n");
}
