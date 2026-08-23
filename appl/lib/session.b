implement Session;

#
# Decode a session recording into actions, and perform them.
#
# The recording is what emu's inputrec.c wrote: key presses and releases and
# pointer states, with the time each arrived. That reproduces a session exactly
# and tells you nothing about it. What a reader wants - and what a script needs
# in order to be edited - is "typed echo hello", "clicked at 252,290", "waited
# a second and a half".
#
# Performing an action uses the two files the system already provides for it:
# /dev/keyboard, which has always accepted written keys, and /dev/pointerin.
# Both are below every bind, so this drives wm and its clients and anything
# they started, the same way a replay does.
#
include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "string.m";
	str: String;
include "session.m";

Hdrsz:	con 16;		# magic[8] xsize[4] ysize[4]
Recsz:	con 17;		# type[1] msec[4] a[4] b[4] c[4]

Gap:	con 250;	# ms of quiet that becomes an explicit wait
Dblms:	con 500;	# two clicks closer than this are one double click
Slop:	con 4;		# pixels a click may move and still be a click

kfd, pfd: ref Sys->FD;

init(): string
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil)
		return sprint("cannot load %s: %r", String->PATH);
	return nil;
}

g32b(b: array of byte, o: int): int
{
	return (int b[o]<<24) | (int b[o+1]<<16) | (int b[o+2]<<8) | int b[o+3];
}

# Special keys worth a name. Anything else printable becomes text, and a key
# with no name here is written as its number so that nothing is silently lost.
keynames := array[] of {
	(16r0a, "Return"), (16r0d, "Return"), (16r1b, "Esc"), (16r08, "Backspace"),
	(16r09, "Tab"), (16r7f, "Delete"),
	(Spec|16r10, "Home"), (Spec|16r11, "End"), (Spec|16r12, "Up"),
	(Spec|16r13, "Down"), (Spec|16r14, "Left"), (Spec|16r15, "Right"),
	(Spec|16r16, "Pgup"), (Spec|16r17, "Pgdown"), (Spec|16r64, "Del"),
};

keyname(r: int): string
{
	for(i := 0; i < len keynames; i++){
		(c, n) := keynames[i];
		if(c == r)
			return n;
	}
	return sprint("%d", r);
}

keycode(s: string): int
{
	for(i := 0; i < len keynames; i++){
		(c, n) := keynames[i];
		if(n == s)
			return c;
	}
	if(s != nil && s[0] >= '0' && s[0] <= '9')
		return int s;
	return -1;
}

# A release, which a reader never wants to see. The range collides with the
# German dead keys (Spec|16rf00), an ambiguity in the encoding itself rather
# than in this: a release cannot be told from Grave, Acute or Circumflex.
isrelease(r: int): int
{
	return r >= Keyup && r <= Keyup|16r7ff;
}

istext(r: int): int
{
	if(r >= 16r20 && r < 16r7f)
		return 1;
	return r >= 16ra0 && r < Spec;
}

Action.script(a: self ref Action): string
{
	case a.kind {
	Atype =>	return "session type " + quote(a.text);
	Akey =>		return "session key " + a.text;
	Aclick =>	return sprint("session click %d %d %d", a.x, a.y, a.b);
	Adouble =>	return sprint("session doubleclick %d %d %d", a.x, a.y, a.b);
	Adrag =>	return sprint("session drag %d %d %d %d %d", a.x, a.y, a.x2, a.y2, a.b);
	Amove =>	return sprint("session move %d %d", a.x, a.y);
	Await =>	return sprint("session wait %d.%.3d", a.x/1000, a.x%1000);
	Aresize =>	return sprint("session resize %d %d", a.x, a.y);
	Apause =>	return "session pause";
	}
	return nil;
}

# sh quoting: single quotes, with an embedded quote doubled
quote(s: string): string
{
	q := "'";
	for(i := 0; i < len s; i++){
		if(s[i] == '\'')
			q += "'";
		q += s[i:i+1];
	}
	return q + "'";
}

opendevs(): string
{
	if(kfd == nil){
		kfd = sys->open("/dev/keyboard", Sys->OWRITE);
		if(kfd == nil)
			return sprint("cannot open /dev/keyboard: %r");
	}
	if(pfd == nil){
		pfd = sys->open("/dev/pointerin", Sys->OWRITE);
		if(pfd == nil)
			return sprint("cannot open /dev/pointerin: %r");
	}
	return nil;
}

putkey(s: string): string
{
	b := array of byte s;
	if(sys->write(kfd, b, len b) != len b)
		return sprint("write to /dev/keyboard: %r");
	return nil;
}

# The time is given explicitly rather than left to the clock, because a
# consumer decides a double click by the difference between the times two
# events carry - see appl/acme/text.b - so a script that means a double click
# has to say so instead of hoping two writes land close enough together.
#
# The stamps are not enough on their own. A press and a release written
# back to back arrive microseconds apart however they are stamped, and a
# widget then sees a button that was never really held: one click in five was
# lost that way against a real Tk button. So the delivery is spaced to match
# what the stamps claim.
putptr(x, y, b, msec: int): string
{
	s := array of byte sprint("%d %d %d %d", x, y, b, msec);
	if(sys->write(pfd, s, len s) != len s)
		return sprint("write to /dev/pointerin: %r");
	return nil;
}

Action.play(a: self ref Action): string
{
	if((e := opendevs()) != nil)
		return e;
	t := sys->millisec();
	case a.kind {
	Atype =>
		return putkey(a.text);
	Akey =>
		c := keycode(a.text);
		if(c < 0)
			return sprint("no such key: %s", a.text);
		return putkey(sprint("%c", c));
	Amove =>
		return putptr(a.x, a.y, 0, t);
	Aclick =>
		if((e = putptr(a.x, a.y, 0, t)) != nil)
			return e;
		sys->sleep(10);
		if((e = putptr(a.x, a.y, a.b, t+10)) != nil)
			return e;
		sys->sleep(20);
		return putptr(a.x, a.y, 0, t+30);
	Adouble =>
		if((e = putptr(a.x, a.y, 0, t)) != nil)
			return e;
		sys->sleep(10);
		if((e = putptr(a.x, a.y, a.b, t+10)) != nil)
			return e;
		sys->sleep(20);
		if((e = putptr(a.x, a.y, 0, t+30)) != nil)
			return e;
		sys->sleep(90);
		if((e = putptr(a.x, a.y, a.b, t+120)) != nil)
			return e;
		sys->sleep(30);
		return putptr(a.x, a.y, 0, t+150);
	Adrag =>
		if((e = putptr(a.x, a.y, 0, t)) != nil)
			return e;
		sys->sleep(10);
		if((e = putptr(a.x, a.y, a.b, t+10)) != nil)
			return e;
		# a few intermediate points, so a widget tracking the drag sees
		# it move rather than teleport
		sys->sleep(10);
		for(i := 1; i <= 4; i++){
			x := a.x + (a.x2-a.x)*i/5;
			y := a.y + (a.y2-a.y)*i/5;
			if((e = putptr(x, y, a.b, t+10+i*20)) != nil)
				return e;
			sys->sleep(20);
		}
		if((e = putptr(a.x2, a.y2, a.b, t+110)) != nil)
			return e;
		sys->sleep(20);
		return putptr(a.x2, a.y2, 0, t+130);
	Await =>
		sys->sleep(a.x);
		return nil;
	Aresize =>
		return "resize cannot be performed: the host owns the window size";
	Apause =>
		return nil;		# the shell module handles this one
	}
	return nil;
}

Keyms:	con 20;		# between characters of a run of typing
Clickms: con 30;	# a button held for a click
Sepms:	con 600;	# least gap between two clicks that are not a double

pbe32(b: array of byte, o, v: int)
{
	b[o] = byte (v>>24);
	b[o+1] = byte (v>>16);
	b[o+2] = byte (v>>8);
	b[o+3] = byte v;
}

Ev: adt {
	kind:	int;
	at:	int;
	a, b, c: int;
};

ev(l: list of Ev, kind, at, a, b, c: int): list of Ev
{
	return Ev(kind, at, a, b, c) :: l;
}

# a key as the hardware would have delivered it: a press and a release
kev(l: list of Ev, at, r: int): list of Ev
{
	l = ev(l, 'k', at, r, 0, 0);
	return ev(l, 'k', at+Keyms/2, Keyup|(r&16r7ff), 0, 0);
}

write(acts: array of ref Action, path: string): string
{
	evs: list of Ev;
	t := 0;
	# where the decoder will measure the next gap from - not t, which has
	# run on past the last event of each action. Without this a wait grows
	# by one key-time every time a script is compiled and decoded again.
	last := 0;
	lastclick := -Sepms;
	for(i := 0; i < len acts; i++){
		a := acts[i];
		case a.kind {
		Await =>
			t = last + a.x;
			continue;
		Atype =>
			for(j := 0; j < len a.text; j++){
				evs = kev(evs, t, a.text[j]);
				last = t;
				t += Keyms;
			}
		Akey =>
			c := keycode(a.text);
			if(c < 0)
				return sprint("no such key: %s", a.text);
			evs = kev(evs, t, c);
			last = t;
			t += Keyms;
		Amove =>
			evs = ev(evs, 'm', t, a.x, a.y, 0);
			last = t;
			t += Keyms;
		Aclick or Adouble =>
			# two clicks are only two clicks if they are far
			# enough apart to not be read as one, so a script
			# with no wait between them still means what it says
			if(a.kind == Aclick && t - lastclick < Sepms)
				t = lastclick + Sepms;
			# the press goes at t, with no move in front of it: the
			# press carries its own position, and a gap is measured
			# to the press, so anything earlier makes the wait that
			# decodes out of this longer than the one that went in
			evs = ev(evs, 'm', t, a.x, a.y, a.b);
			evs = ev(evs, 'm', t+Clickms, a.x, a.y, 0);
			t += Clickms;
			if(a.kind == Adouble){
				t += 90;
				evs = ev(evs, 'm', t, a.x, a.y, a.b);
				evs = ev(evs, 'm', t+Clickms, a.x, a.y, 0);
				t += Clickms;
			}
			last = t;
			lastclick = t;
		Adrag =>
			evs = ev(evs, 'm', t, a.x, a.y, a.b);
			for(j := 1; j <= 4; j++){
				x := a.x + (a.x2-a.x)*j/5;
				y := a.y + (a.y2-a.y)*j/5;
				evs = ev(evs, 'm', t+5+j*10, x, y, a.b);
			}
			evs = ev(evs, 'm', t+50, a.x2, a.y2, a.b);
			evs = ev(evs, 'm', t+70, a.x2, a.y2, 0);
			t += 70;
			last = t;
			lastclick = t;
		Aresize =>
			evs = ev(evs, 'r', t, a.x, a.y, 0);
			last = t;
			t += Keyms;
		Apause =>
			;			# nothing the hardware ever did
		}
	}

	n := len evs;
	r := array[n] of Ev;
	for(i = n-1; i >= 0; i--){
		r[i] = hd evs;
		evs = tl evs;
	}
	buf := array[Hdrsz + n*Recsz] of byte;
	buf[0:] = array of byte "inferec1";
	pbe32(buf, 8, 1024);
	pbe32(buf, 12, 768);
	for(i = 0; i < n; i++){
		o := Hdrsz + i*Recsz;
		buf[o] = byte r[i].kind;
		pbe32(buf, o+1, r[i].at);
		pbe32(buf, o+5, r[i].a);
		pbe32(buf, o+9, r[i].b);
		pbe32(buf, o+13, r[i].c);
	}
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sprint("cannot create %s: %r", path);
	if(sys->write(fd, buf, len buf) != len buf)
		return sprint("cannot write %s: %r", path);
	return nil;
}

span(a: array of ref Action): int
{
	t := 0;
	for(i := 0; i < len a; i++)
		if(a[i].at > t)
			t = a[i].at;
	return t;
}

parse(words: list of string): (ref Action, string)
{
	if(words == nil)
		return (nil, "empty action");
	verb := hd words;
	words = tl words;
	n := len words;
	a := ref Action;
	a.b = 1;
	case verb {
	"type" =>
		if(n != 1)
			return (nil, "usage: type text");
		a.kind = Atype;
		a.text = hd words;
	"key" =>
		if(n != 1)
			return (nil, "usage: key name");
		a.kind = Akey;
		a.text = hd words;
	"move" =>
		if(n != 2)
			return (nil, "usage: move x y");
		a.kind = Amove;
		(a.x, a.y) = (int hd words, int hd tl words);
	"click" or "doubleclick" =>
		if(n != 2 && n != 3)
			return (nil, "usage: " + verb + " x y [button]");
		if(verb == "click")
			a.kind = Aclick;
		else
			a.kind = Adouble;
		(a.x, a.y) = (int hd words, int hd tl words);
		if(n == 3)
			a.b = int hd tl tl words;
	"drag" =>
		if(n != 4 && n != 5)
			return (nil, "usage: drag x0 y0 x1 y1 [button]");
		a.kind = Adrag;
		a.x = int hd words; words = tl words;
		a.y = int hd words; words = tl words;
		a.x2 = int hd words; words = tl words;
		a.y2 = int hd words; words = tl words;
		if(words != nil)
			a.b = int hd words;
	"wait" =>
		if(n != 1)
			return (nil, "usage: wait seconds");
		a.kind = Await;
		a.x = int (real hd words * 1000.0);
	"resize" =>
		if(n != 2)
			return (nil, "usage: resize w h");
		a.kind = Aresize;
		(a.x, a.y) = (int hd words, int hd tl words);
	"pause" =>
		a.kind = Apause;
	* =>
		return (nil, "no such action: " + verb);
	}
	return (a, nil);
}

read(path: string): (array of ref Action, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sprint("%s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sprint("stat %s: %r", path));
	buf := array[int d.length] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		return (nil, sprint("short read of %s", path));
	if(len buf < Hdrsz || string buf[0:8] != "inferec1")
		return (nil, path + " is not an input recording");

	acts: list of ref Action;
	last := -1;		# time of the previous action, for the waits
	text := "";		# characters accumulated into one type action
	texttime := 0;		# when the run started
	lasttext := 0;		# and when its last character arrived

	# pointer state between events
	(px, py, pb) := (-1, -1, 0);
	(downx, downy, downt) := (0, 0, 0);
	moved := 0;
	lastclickt := -Dblms;
	(lastclickx, lastclicky) := (-1, -1);
	pendmove := 0;

	for(off := Hdrsz; off + Recsz <= len buf; off += Recsz){
		kind := int buf[off];
		at := g32b(buf, off+1);
		v1 := g32b(buf, off+5);
		v2 := g32b(buf, off+9);
		v3 := g32b(buf, off+13);

		case kind {
		'k' =>
			if(isrelease(v1))
				continue;
			if(istext(v1)){
				# a long pause in the middle of typing ends the
				# run: otherwise "a", two seconds, "b" decodes
				# as typing "ab" and the pause - which is the
				# whole point of recording times - is lost
				if(text != "" && at - lasttext >= Gap){
					(acts, last) = flushtext(acts, text, texttime, lasttext, last);
					text = "";
				}
				if(text == "")
					texttime = at;
				text[len text] = v1;
				lasttext = at;
				continue;
			}
			# a named key ends any run of text before it
			(acts, last) = flushtext(acts, text, texttime, lasttext, last);
			text = "";
			(acts, last) = addwait(acts, last, at);
			a := ref Action(Akey, at, keyname(v1), 0, 0, 0, 0, 0);
			acts = a :: acts;
			last = at;
		'm' =>
			(x, y, b) := (v1, v2, v3);
			# the very first pointer event has nothing to be
			# compared against: seeding px from it makes it look
			# like no movement at all, and a recording whose only
			# pointer event is one move then decodes to nothing
			firstm := px < 0;
			if(firstm)
				(px, py) = (x, y);
			if(b != 0 && pb == 0){
				(downx, downy, downt) = (x, y, at);
				moved = 0;
				pendmove = 0;
			}else if(b == 0 && pb != 0){
				(acts, last) = flushtext(acts, text, texttime, lasttext, last);
				text = "";
				(acts, last) = addwait(acts, last, downt);
				a: ref Action;
				if(moved)
					a = ref Action(Adrag, downt, nil, downx, downy, x, y, pb);
				else if(at - lastclickt < Dblms
					&& abs(x-lastclickx) <= Slop && abs(y-lastclicky) <= Slop){
					a = ref Action(Adouble, downt, nil, downx, downy, 0, 0, pb);
					# the first of the pair was reported as a
					# click before this one was known to be a
					# double; a double click is one action, so
					# take it back. Only when nothing came
					# between them, which for two clicks less
					# than Gap apart is the ordinary case.
					if(acts != nil && (hd acts).kind == Aclick
					   && abs((hd acts).x - downx) <= Slop
					   && abs((hd acts).y - downy) <= Slop)
						acts = tl acts;
				}
				else
					a = ref Action(Aclick, downt, nil, downx, downy, 0, 0, pb);
				acts = a :: acts;
				last = at;
				lastclickt = at;
				(lastclickx, lastclicky) = (x, y);
			}else if(b != 0){
				if(abs(x-downx) > Slop || abs(y-downy) > Slop)
					moved = 1;
			}else{
				# a run of plain movement: only its end is worth
				# recording, but it is worth recording, because a
				# menu tracks the pointer and a replay that never
				# moves never opens one
				if(firstm || abs(x-px) > Slop || abs(y-py) > Slop)
					pendmove = 1;
			}
			if(pendmove && b == 0){
				# hold it until the movement stops
				# the lookahead reads a whole record, so require one
			if(off + 2*Recsz > len buf || int buf[off+Recsz] != 'm'
				   || g32b(buf, off+Recsz+1) - at > Gap){
					(acts, last) = flushtext(acts, text, texttime, lasttext, last);
					text = "";
					(acts, last) = addwait(acts, last, at);
					acts = ref Action(Amove, at, nil, x, y, 0, 0, 0) :: acts;
					last = at;
					pendmove = 0;
				}
			}
			(px, py, pb) = (x, y, b);
		'r' =>
			(acts, last) = flushtext(acts, text, texttime, lasttext, last);
			text = "";
			(acts, last) = addwait(acts, last, at);
			acts = ref Action(Aresize, at, nil, v1, v2, 0, 0, 0) :: acts;
			last = at;
		}
	}
	(acts, last) = flushtext(acts, text, texttime, lasttext, last);

	n := len acts;
	r := array[n] of ref Action;
	for(i := n-1; i >= 0; i--){
		r[i] = hd acts;
		acts = tl acts;
	}
	return (r, nil);
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

addwait(acts: list of ref Action, last, at: int): (list of ref Action, int)
{
	if(last >= 0 && at - last >= Gap)
		acts = ref Action(Await, last, nil, at-last, 0, 0, 0, 0) :: acts;
	return (acts, last);
}

# the wait goes in front of the run, and time afterwards is measured from the
# run's end rather than its start
flushtext(acts: list of ref Action, text: string, at, end, last: int): (list of ref Action, int)
{
	if(text == "")
		return (acts, last);
	(acts, nil) = addwait(acts, last, at);
	acts = ref Action(Atype, at, text, 0, 0, 0, 0, 0) :: acts;
	return (acts, end);
}
