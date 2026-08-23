implement Command;

#
# Check that session(2) decodes a recording into the actions it should.
#
# It builds recordings rather than making them, because the half of the
# decoder that matters most cannot be exercised any other way here. Clicks,
# double clicks and drags are what the recorded-msec design exists for, and
# synthetic clicks from the host do not arrive on this platform - see
# inputtest(1). Injecting them through /dev/pointerin does not help either:
# that path deliberately does not record, for the same reason writing to
# /dev/keyboard does not, so a recording cannot contain events this machine
# put there itself.
#
# What is left is the decoder's actual input, which is a file in a documented
# format. Building one with known events and checking what comes out tests
# exactly the thing that was otherwise going untested.
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "session.m";
	session: Session;
	Action: import session;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Hdrsz:	con 16;
Recsz:	con 17;

failed := 0;
tmp := "/sessiontest.tmp";

pbe32(b: array of byte, o, v: int)
{
	b[o] = byte (v>>24);
	b[o+1] = byte (v>>16);
	b[o+2] = byte (v>>8);
	b[o+3] = byte v;
}

# an input recording holding the given events, in the format inputrec.c writes
Ev: adt {
	kind:	int;
	at:	int;
	a, b, c: int;
};

build(evs: array of Ev): string
{
	buf := array[Hdrsz + len evs * Recsz] of byte;
	buf[0:] = array of byte "inferec1";
	pbe32(buf, 8, 1024);
	pbe32(buf, 12, 768);
	for(i := 0; i < len evs; i++){
		o := Hdrsz + i*Recsz;
		buf[o] = byte evs[i].kind;
		pbe32(buf, o+1, evs[i].at);
		pbe32(buf, o+5, evs[i].a);
		pbe32(buf, o+9, evs[i].b);
		pbe32(buf, o+13, evs[i].c);
	}
	fd := sys->create(tmp, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sprint("cannot create %s: %r", tmp);
	if(sys->write(fd, buf, len buf) != len buf)
		return sprint("cannot write %s: %r", tmp);
	return nil;
}

# the script a recording decodes to, one line per action
decode(evs: array of Ev): (list of string, string)
{
	if((e := build(evs)) != nil)
		return (nil, e);
	(acts, err) := session->read(tmp);
	if(err != nil)
		return (nil, err);
	r: list of string;
	for(i := len acts - 1; i >= 0; i--)
		r = acts[i].script() :: r;
	return (r, nil);
}

check(what: string, evs: array of Ev, want: list of string)
{
	(got, err) := decode(evs);
	if(err != nil){
		print("FAIL %s: %s\n", what, err);
		failed++;
		return;
	}
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
	print("     wanted:\n");
	for(l := want; l != nil; l = tl l)
		print("       %s\n", hd l);
	print("     got:\n");
	for(l = got; l != nil; l = tl l)
		print("       %s\n", hd l);
	failed++;
}

# a press and release of one key, as the recording holds it
key(at, r: int): array of Ev
{
	return array[] of {Ev('k', at, r, 0, 0), Ev('k', at+8, Session->Keyup|(r&16r7ff), 0, 0)};
}

cat(a: array of array of Ev): array of Ev
{
	n := 0;
	for(i := 0; i < len a; i++)
		n += len a[i];
	r := array[n] of Ev;
	n = 0;
	for(i = 0; i < len a; i++)
		for(j := 0; j < len a[i]; j++)
			r[n++] = a[i][j];
	return r;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	session = load Session Session->PATH;
	if(session == nil){
		print("sessiontest: cannot load %s: %r\n", Session->PATH);
		raise "fail:load";
	}
	if((e := session->init()) != nil){
		print("sessiontest: %s\n", e);
		raise "fail:init";
	}

	# typing: presses become text, releases vanish, and a repeated
	# character survives - the case a decoder that coalesces runs would
	# swallow
	check("typing, with releases dropped and a doubled letter",
		cat(array[] of {key(100,'h'), key(120,'e'), key(140,'l'), key(160,'l'), key(180,'o')}),
		list of {"session type 'hello'"});

	# a named key ends a run of text
	check("a named key ends the text",
		cat(array[] of {key(100,'h'), key(120,'i'), key(140,'\n')}),
		list of {"session type 'hi'", "session key Return"});

	# quiet longer than Gap becomes an explicit wait
	check("a gap becomes a wait",
		cat(array[] of {key(100,'a'), key(2000,'b')}),
		list of {"session type 'a'", "session wait 1.900", "session type 'b'"});

	# press and release in one place is a click
	check("press and release in one place is a click",
		array[] of {
			Ev('m', 1000, 200, 300, 0),
			Ev('m', 1010, 200, 300, 1),
			Ev('m', 1040, 200, 300, 0),
		},
		list of {"session click 200 300 1"});

	# two clicks close together are one double click
	check("two clicks within 500ms are a double click",
		array[] of {
			Ev('m', 1000, 200, 300, 0),
			Ev('m', 1010, 200, 300, 1),
			Ev('m', 1040, 200, 300, 0),
			Ev('m', 1150, 200, 300, 1),
			Ev('m', 1180, 200, 300, 0),
		},
		list of {"session click 200 300 1", "session doubleclick 200 300 1"});

	# far enough apart, they are two clicks
	check("two clicks 900ms apart are not a double click",
		array[] of {
			Ev('m', 1000, 200, 300, 0),
			Ev('m', 1010, 200, 300, 1),
			Ev('m', 1040, 200, 300, 0),
			Ev('m', 1900, 200, 300, 1),
			Ev('m', 1930, 200, 300, 0),
		},
		list of {"session click 200 300 1", "session wait 0.860", "session click 200 300 1"});

	# movement while a button is held is a drag
	check("movement with a button down is a drag",
		array[] of {
			Ev('m', 1000, 200, 300, 0),
			Ev('m', 1010, 200, 300, 1),
			Ev('m', 1030, 240, 330, 1),
			Ev('m', 1050, 280, 360, 1),
			Ev('m', 1070, 280, 360, 0),
		},
		list of {"session drag 200 300 280 360 1"});

	# a resize is an action even though it cannot be performed
	check("a resize decodes",
		array[] of {Ev('r', 500, 800, 600, 0)},
		list of {"session resize 800 600"});

	# a recording ending on a move must not read past its last record
	check("a trailing move does not run off the end",
		array[] of {
			Ev('m', 1000, 200, 300, 0),
			Ev('m', 1100, 400, 500, 0),
		},
		list of {"session move 400 500"});

	sys->remove(tmp);
	if(failed){
		print("sessiontest: %d checks failed\n", failed);
		raise "fail:test";
	}
	print("PASS\n");
}
