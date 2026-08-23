implement Command;

#
# Turn a Styx trace into a legible account of what a session did.
#
# A raw trace is a sequence of messages about numbered fids, which is the wrong
# vocabulary for reading: nothing in it says "the program opened
# /dis/wm/toolbar.dis". Walks are what give fids their meaning, so this follows
# them, keeps a name for every fid, and reports opens, reads and writes against
# paths and times.
#
# Writes are shown as text when they are short and printable, because that is
# where the interesting part of a session usually is - a Tk command, a line to
# a control file, a draw request - and a byte count says nothing about it.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "arg.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Fid: adt {
	fid:	int;
	path:	string;
};

# A walk is only real once its reply says so, so the name it would give
# has to be held until then - and held per tag, not in a single slot.
# Several processes share one name space and one trace, so their walks
# interleave: Twalk(A), Twalk(B), Rwalk(A), Rwalk(B). A single slot gives
# A's reply B's path and leaves B's fid unnamed, and both mistakes look
# entirely plausible in the output.
Pend: adt {
	tag:	int;
	newfid:	int;
	nnames:	int;
	path:	string;
};

fids: list of ref Fid;
pends: list of ref Pend;
showdata := 0;
minbytes := 0;
only: string;

usage()
{
	fprint(sys->fildes(2), "usage: styxlog [-d] [-b nbytes] [-f substring] tracefile\n");
	raise "fail:usage";
}

lookup(f: int): ref Fid
{
	for(l := fids; l != nil; l = tl l)
		if((hd l).fid == f)
			return hd l;
	return nil;
}

setfid(f: int, p: string)
{
	q := lookup(f);
	if(q != nil){
		q.path = p;
		return;
	}
	fids = ref Fid(f, p) :: fids;
}

dropfid(f: int)
{
	r: list of ref Fid;
	for(l := fids; l != nil; l = tl l)
		if((hd l).fid != f)
			r = hd l :: r;
	fids = r;
}

addpend(p: ref Pend)
{
	droppend(p.tag);
	pends = p :: pends;
}

droppend(tag: int): ref Pend
{
	found: ref Pend;
	r: list of ref Pend;
	for(l := pends; l != nil; l = tl l){
		if((hd l).tag == tag && found == nil)
			found = hd l;
		else
			r = hd l :: r;
	}
	pends = r;
	return found;
}

pathof(f: int): string
{
	q := lookup(f);
	if(q == nil)
		return sprint("<fid %d>", f);
	return q.path;
}

join(base: string, names: array of string): string
{
	p := base;
	for(i := 0; i < len names; i++){
		if(names[i] == "..")
			continue;		# good enough for a log
		if(p == "/" || p == "")
			p = "/" + names[i];
		else
			p = p + "/" + names[i];
	}
	return p;
}

# Short, printable writes are worth seeing; anything else is a byte count.
astext(d: array of byte): string
{
	if(len d == 0 || len d > 120)
		return nil;
	for(i := 0; i < len d; i++){
		c := int d[i];
		if(c < 16r20 && c != '\n' && c != '\t')
			return nil;
		if(c >= 16r7f)
			return nil;
	}
	s := string d;
	# one line, so the log stays one event per line
	t := "";
	for(i = 0; i < len s; i++)
		if(s[i] == '\n')
			t += "\\n";
		else
			t += s[i:i+1];
	return t;
}

g32b(b: array of byte, o: int): int
{
	return (int b[o]<<24) | (int b[o+1]<<16) | (int b[o+2]<<8) | int b[o+3];
}

g64b(b: array of byte, o: int): big
{
	v := big 0;
	for(i := 0; i < 8; i++)
		v = (v<<8) | big (int b[o+i] & 16rff);
	return v;
}

want(p: string): int
{
	if(only == nil)
		return 1;
	for(i := 0; i + len only <= len p; i++)
		if(p[i:i+len only] == only)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	arg := load Arg Arg->PATH;
	if(styx == nil || arg == nil){
		print("styxlog: load: %r\n");
		raise "fail:load";
	}
	styx->init();

	arg->init(argv);
	arg->setusage("styxlog [-d] [-b nbytes] [-f substring] tracefile");
	while((o := arg->opt()) != 0)
		case o {
		'd' =>	showdata++;		# show write data even when long
		'b' =>	minbytes = int arg->earg();	# ignore reads/writes below this
		'f' =>	only = arg->earg();	# only paths containing this
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil || tl argv != nil)
		usage();

	fd := sys->open(hd argv, Sys->OREAD);
	if(fd == nil){
		fprint(sys->fildes(2), "styxlog: %s: %r\n", hd argv);
		raise "fail:open";
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		raise "fail:stat";
	buf := array[int d.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf){
		fprint(sys->fildes(2), "styxlog: short read\n");
		raise "fail:read";
	}

	t0 := big 0;
	nopen := 0;
	nread := 0;
	nwrite := 0;
	rbytes := big 0;
	wbytes := big 0;

	for(off := 0; off + 13 <= len buf;){
		dir := int buf[off];
		tm := g64b(buf, off+1);
		l := g32b(buf, off+9);
		if(l < 0 || off + 13 + l > len buf)
			break;
		msg := buf[off+13:off+13+l];
		off += 13 + l;
		if(t0 == big 0)
			t0 = tm;
		at := real (tm - t0) / 1.0e6;

		if(dir == 'T'){
			(nil, m) := Tmsg.unpack(msg);
			if(m == nil)
				continue;
			pick x := m {
			Attach =>
				setfid(x.fid, "/");
			Walk =>
				addpend(ref Pend(x.tag, x.newfid, len x.names,
					join(pathof(x.fid), x.names)));
			Open =>
				p := pathof(x.fid);
				if(want(p)){
					nopen++;
					print("%9.3f  open   %s\n", at, p);
				}
			Create =>
				p := join(pathof(x.fid), array[] of {x.name});
				if(want(p))
					print("%9.3f  create %s\n", at, p);
			Write =>
				p := pathof(x.fid);
				if(want(p) && len x.data >= minbytes){
					nwrite++;
					wbytes += big len x.data;
					s := astext(x.data);
					if(s != nil)
						print("%9.3f  write  %s: %s\n", at, p, s);
					else
						print("%9.3f  write  %s (%d bytes)\n", at, p, len x.data);
				}
			Clunk =>
				dropfid(x.fid);
			}
		}else{
			(nil, m) := Rmsg.unpack(msg);
			if(m == nil)
				continue;
			pick x := m {
			Walk =>
				# a short walk means it stopped early, so the
				# new fid was never established and naming it
				# would invent a path deeper than it is
				p := droppend(x.tag);
				if(p != nil && len x.qids == p.nnames)
					setfid(p.newfid, p.path);
			Error =>
				droppend(x.tag);
			Read =>
				# attributing a read needs the request it answers;
				# the count is what matters here, and the path is
				# reported by the open above
				if(len x.data > 0){
					nread++;
					rbytes += big len x.data;
				}
			}
		}
	}
	fprint(sys->fildes(2),
		"styxlog: %d opens, %d reads (%bd bytes), %d writes (%bd bytes)\n",
		nopen, nread, rbytes, nwrite, wbytes);
}
