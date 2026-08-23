implement Command;

#
# Run a program against a recorded name space instead of a real one.
#
# iostats -t records every Styx message that crossed between a program and its
# name space, with the time it crossed. This serves that recording back: the
# program is given a name space that answers from the trace, in the order and
# at the pace it originally answered.
#
# Because devices in Inferno are files, that covers a great deal - pointer and
# keyboard input, the draw protocol, /dev/time, /dev/random - so a session that
# was driven by hand can be run again without the hand.
#
# Divergence is the interesting output, not an error. If the program asks for
# something other than what it asked for when the trace was made, then
# something outside the trace is affecting it, and where that first happens is
# exactly what one wants to know. So a mismatch reports both messages and
# stops, rather than trying to carry on.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "arg.m";
include "sh.m";
	sh: Sh;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

# Command is declared by sh.m, which is included above.

Maxmsg: con 128*1024+Styx->IOHDRSZ;

Rec: adt {
	dir:	int;		# 'T' or 'R'
	time:	big;		# microseconds, from /dev/time when recorded
	msg:	array of byte;	# the message verbatim
};

recs: array of Rec;
nrec: int;
verbose := 0;
nopace := 0;
diverged := 0;

usage()
{
	fprint(sys->fildes(2), "usage: styxreplay [-v] [-n] tracefile cmd [args...]\n");
	raise "fail:usage";
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

# Styx is little-endian: size[4] type[1] tag[2] ...
gettag(m: array of byte): int
{
	if(len m < 7)
		return -1;
	return int m[5] | (int m[6]<<8);
}

settag(m: array of byte, t: int)
{
	if(len m < 7)
		return;
	m[5] = byte t;
	m[6] = byte (t>>8);
}

mtype(m: array of byte): int
{
	if(len m < 5)
		return -1;
	return int m[4];
}

# Whether two requests mean the same thing.
#
# Not a byte comparison. Tags and fids are the client's own bookkeeping and it
# is free to number them differently on a second run - the first attempt here
# compared bytes and reported a divergence on the very first attach, where the
# only difference was fid 34 against fid 23.
#
# Fids need no translation table either, which is the useful part: a reply
# never mentions a fid. Rwalk and Ropen carry qids, which are the server's
# names for things, and those come from the trace. So the client may number
# its fids however it likes, and what is compared is what the request actually
# asks for.
tsame(a, b: ref Tmsg): string
{
	if(a == nil || b == nil)
		return "unreadable message";
	if(tagof a != tagof b)
		return "different kind of request";
	pick x := a {
	Version =>
		pick y := b { Version =>
			if(x.msize != y.msize || x.version != y.version)
				return "different version or message size";
		}
	Attach =>
		pick y := b { Attach =>
			if(x.uname != y.uname || x.aname != y.aname)
				return "different user or tree";
		}
	Walk =>
		pick y := b { Walk =>
			if(len x.names != len y.names)
				return "different number of path elements";
			for(i := 0; i < len x.names; i++)
				if(x.names[i] != y.names[i])
					return "walking to " + y.names[i] + " instead of " + x.names[i];
		}
	Open =>
		pick y := b { Open =>
			if(x.mode != y.mode)
				return "different open mode";
		}
	Create =>
		pick y := b { Create =>
			if(x.name != y.name || x.perm != y.perm || x.mode != y.mode)
				return "creating something else";
		}
	Read =>
		pick y := b { Read =>
			if(x.offset != y.offset || x.count != y.count)
				return "reading a different range";
		}
	Write =>
		pick y := b { Write =>
			if(x.offset != y.offset || len x.data != len y.data)
				return "writing a different range";
			for(i := 0; i < len x.data; i++)
				if(x.data[i] != y.data[i])
					return "writing different bytes";
		}
	}
	return nil;
}

readtrace(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		fprint(sys->fildes(2), "styxreplay: %s: %r\n", path);
		raise "fail:open";
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0){
		fprint(sys->fildes(2), "styxreplay: stat %s: %r\n", path);
		raise "fail:stat";
	}
	buf := array[int d.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf){
		fprint(sys->fildes(2), "styxreplay: short read of %s\n", path);
		raise "fail:read";
	}
	n := 0;
	for(off := 0; off + 13 <= len buf;){
		l := g32b(buf, off+9);
		if(l < 0 || off + 13 + l > len buf)
			break;
		off += 13 + l;
		n++;
	}
	recs = array[n] of Rec;
	i := 0;
	for(off = 0; off + 13 <= len buf && i < n;){
		l := g32b(buf, off+9);
		if(l < 0 || off + 13 + l > len buf)
			break;
		recs[i].dir = int buf[off];
		recs[i].time = g64b(buf, off+1);
		recs[i].msg = buf[off+13:off+13+l];
		off += 13 + l;
		i++;
	}
	nrec = i;
}

# The next recorded request, and the reply that followed it.
nextpair(from: int): (int, int)
{
	t := -1;
	for(i := from; i < nrec; i++){
		if(recs[i].dir == 'T'){
			t = i;
			break;
		}
	}
	if(t < 0)
		return (-1, -1);
	for(i = t+1; i < nrec; i++)
		if(recs[i].dir == 'R' && gettag(recs[i].msg) == gettag(recs[t].msg))
			return (t, i);
	return (t, -1);
}

server(fd: ref Sys->FD, done: chan of int)
{
	sys->pctl(0, nil);
	at := 0;
	nserved := 0;
	for(;;){
		(a, err) := styx->readmsg(fd, Maxmsg);
		if(err != nil || a == nil)
			break;
		(ti, ri) := nextpair(at);
		if(ti < 0){
			(nil, m) := Tmsg.unpack(a);
			fprint(sys->fildes(2),
				"styxreplay: the trace is exhausted but the program asked for more:\n"+
				"    %s\n", msgtext(m));
			diverged = 1;
			break;
		}
		(nil, got) := Tmsg.unpack(a);
		(nil, want) := Tmsg.unpack(recs[ti].msg);
		if((why := tsame(want, got)) != nil){
			fprint(sys->fildes(2),
				"styxreplay: diverged at message %d of the trace: %s\n"+
				"    recorded: %s\n"+
				"    now:      %s\n", ti, why, msgtext(want), msgtext(got));
			diverged = 1;
			break;
		}
		if(ri < 0){
			fprint(sys->fildes(2),
				"styxreplay: the trace records no reply to message %d\n", ti);
			diverged = 1;
			break;
		}

		# Wait as long as it waited. This is what makes a replay run at
		# the pace of the session it came from rather than as fast as
		# the machine can go, which matters when what was recorded was
		# somebody typing or moving a pointer.
		if(!nopace){
			ms := int ((recs[ri].time - recs[ti].time) / big 1000);
			if(ms > 0)
				sys->sleep(ms);
		}

		r := array[len recs[ri].msg] of byte;
		r[0:] = recs[ri].msg;
		settag(r, gettag(a));
		if(verbose){
			(nil, rm) := Rmsg.unpack(r);
			fprint(sys->fildes(2), "  %s -> %s\n", msgtext(got), rmsgtext(rm));
		}
		if(sys->write(fd, r, len r) != len r)
			break;
		nserved++;
		at = ti + 1;
	}
	# Drop the last reference to the pipe, so a program still waiting for a
	# reply sees the connection go away instead of waiting for ever.
	fd = nil;
	if(!diverged && verbose)
		fprint(sys->fildes(2), "styxreplay: %d of %d recorded exchanges replayed\n",
			nserved, nrec/2);
	done <-= 1;
}

msgtext(m: ref Tmsg): string
{
	if(m == nil)
		return "(unreadable)";
	return m.text();
}

rmsgtext(m: ref Rmsg): string
{
	if(m == nil)
		return "(unreadable)";
	return m.text();
}

runcmd(ctxt: ref Draw->Context, args: list of string, fsfd: ref Sys->FD, done: chan of int)
{
	{
		sys->pctl(Sys->FORKNS|Sys->FORKFD, nil);
		if(sys->mount(fsfd, nil, "/", Sys->MREPL, "") < 0)
			fatal(sprint("can't mount the recorded name space on /: %r"));
		fsfd = nil;
		sys->bind("#e", "/env", Sys->MREPL|Sys->MCREATE);
		sys->bind("#d", "/fd", Sys->MREPL);
		sh->run(ctxt, args);
	}exception{
	"fail:*" =>
		;
	* =>
		raise;
	}
	done <-= 1;
}

fatal(s: string)
{
	fprint(sys->fildes(2), "styxreplay: %s\n", s);
	raise "fail:error";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	sh = load Sh Sh->PATH;
	arg := load Arg Arg->PATH;
	if(styx == nil || sh == nil || arg == nil){
		print("styxreplay: load: %r\n");
		raise "fail:load";
	}
	styx->init();

	arg->init(argv);
	arg->setusage("styxreplay [-v] [-n] tracefile cmd [args...]");
	while((o := arg->opt()) != 0)
		case o {
		'v' =>	verbose++;
		'n' =>	nopace++;	# as fast as possible, ignoring the recorded pacing
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil || tl argv == nil)
		usage();
	tracefile := hd argv;
	argv = tl argv;

	readtrace(tracefile);
	if(nrec == 0)
		fatal(sprint("%s holds no records", tracefile));

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0)
		fatal(sprint("can't create a pipe: %r"));

	cdone := chan of int;
	sdone := chan of int;
	spawn runcmd(ctxt, argv, p[0], cdone);
	p[0] = nil;
	spawn server(p[1], sdone);
	p[1] = nil;

	<-cdone;
	<-sdone;
	if(diverged)
		raise "fail:diverged";
}
