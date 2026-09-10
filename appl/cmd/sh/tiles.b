implement Shellbuiltin;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "sh.m";
	sh: Sh;
	Listnode, Context: import sh;
	myself: Shellbuiltin;
include "tiles.m";
	tiles: Tiles;
	Screen: import tiles;
include "keyhold.m";
	keyhold: Keyhold;
	Binding: import keyhold;
include "keyboard.m";
include "frameclock.m";
	fclock: Frameclock;

# A loadable sh(1) module giving shell scripts tiles(2)'s own command
# language, the same way sh-plot(1) gives them plot(2)'s and sh-tk(1)
# gives them tk(2)'s.
#
# What that is for: tiles(2) draws from named palettes, named sheets of
# art and named surfaces, all of them made by text, and its art and its
# levels are ordinary files.  Put those two together and a screenful of
# 8-bit graphics is something a shell script can build - which is the
# same trick that makes a Tk window something a shell script can build,
# and for the same reason.  Nothing here knows what any of the commands
# mean; everything after the handle is forwarded verbatim to
# Screen.cmd(), and only "new", "del" and "draw" - this module's own
# additions, the window tiles(2) has no opinion about - are special
# cased first words.
#
# A forwarded command's own failure is reported as a soft $status, the
# convention sh-tk(1) uses for a bad raw tk command; only handle and
# usage errors raise.

Handle: adt {
	id:	int;
	top:	ref Tk->Toplevel;
	buffer:	ref Image;
	scr:	ref Screen;
	want:	Point;
	shown:	int;
	# input: the actions a script has named, the table keyhold(2) reads
	# them with, and what is held now
	acts:	array of string;
	binds:	array of (int, int);
	kb:	ref Binding;
	held:	int;
	prev:	int;
	last:	int;		# millisec, for pace
	tick:	chan of int;	# the frame clock, made on first use
	tickms:	int;
	served:	int;		# an event file has the keyboard
};

handles: array of list of ref Handle;
nexthandle := 1;

initbuiltin(ctxt: ref Context, shmod: Sh): string
{
	sys = load Sys Sys->PATH;
	sh = shmod;
	myself = load Shellbuiltin "$self";
	if(myself == nil)
		ctxt.fail("bad module", sys->sprint("tiles: cannot load self: %r"));
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		ctxt.fail("bad module", sys->sprint("tiles: cannot load %s: %r", Tk->PATH));
	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		ctxt.fail("bad module", sys->sprint("tiles: cannot load %s: %r", Tkclient->PATH));
	tkclient->init();
	tiles = load Tiles Tiles->PATH;
	if(tiles == nil)
		ctxt.fail("bad module", sys->sprint("tiles: cannot load %s: %r", Tiles->PATH));
	tiles->init();
	keyhold = load Keyhold Keyhold->PATH;
	if(keyhold == nil)
		ctxt.fail("bad module", sys->sprint("tiles: cannot load %s: %r", Keyhold->PATH));
	fclock = load Frameclock Frameclock->PATH;
	if(fclock != nil)
		fclock->init();
	handles = array[16] of list of ref Handle;
	ctxt.addbuiltin("tiles", myself);
	ctxt.addsbuiltin("tiles", myself);
	return nil;
}

whatis(nil: ref Sh->Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

getself(): Shellbuiltin
{
	return myself;
}

# usage:
#   id := ${tiles new WxH [scale] [title]}
#   tiles $id palette steel dark.black dark.azure mid.cyan light.cyan
#   tiles $id sheet art /lib/tiles/demo.chr
#   tiles $id surface level 256 96 dark.black
#   tiles $id map level art /lib/tiles/demo.map
#   tiles $id draw level
#   tiles del $id
runbuiltin(ctxt: ref Context, nil: Sh,
		argv: list of ref Listnode, nil: int): string
{
	if(tl argv == nil)
		ctxt.fail("usage", "usage: tiles (new|del|<id> args...)");
	argv = tl argv;
	w := (hd argv).word;
	if(w == "new"){
		remark(ctxt, string newhandle(ctxt, tl argv));
		return nil;
	}
	if(w == "del"){
		for(argv = tl argv; argv != nil; argv = tl argv)
			delhandle(int (hd argv).word);
		return nil;
	}
	if(!isnum(w))
		ctxt.fail("usage", "usage: tiles (new|del|<id> args...)");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: tiles <id> (draw surface|command...)");
	if((hd rest).word == "draw"){
		if(tl rest == nil)
			ctxt.fail("usage", "usage: tiles <id> draw surface");
		return drawsurf(ctxt, h, (hd tl rest).word);
	}
	if((hd rest).word == "write"){
		if(tl rest == nil || tl tl rest == nil)
			ctxt.fail("usage", "usage: tiles <id> write surface file");
		return writesurf(ctxt, h, (hd tl rest).word, (hd tl tl rest).word);
	}
	if((hd rest).word == "bind"){
		e := dobind(h, tl rest);
		if(e != nil){
			remark(ctxt, e);
			return e;
		}
		return nil;
	}
	if((hd rest).word == "pace"){
		if(tl rest == nil)
			ctxt.fail("usage", "usage: tiles <id> pace ms");
		pace(h, int (hd tl rest).word);
		return nil;
	}
	if((hd rest).word == "events"){
		if(tl rest == nil)
			ctxt.fail("usage", "usage: tiles <id> events NAME [ms]");
		ms := 0;
		if(tl tl rest != nil)
			ms = int (hd tl tl rest).word;
		e := events(ctxt, h, (hd tl rest).word, ms);
		if(e != nil){
			remark(ctxt, e);
			return e;
		}
		return nil;
	}
	if((hd rest).word == "keys" || (hd rest).word == "pressed"){
		remark(ctxt, readkeys(ctxt, h, (hd rest).word == "pressed"));
		return nil;
	}
	# Everything else is tiles(2)'s own language, unrecognized here.
	r := h.scr.cmd(concat(rest));
	if(len r > 0 && r[0] == '!'){
		remark(ctxt, r);
		return r;
	}
	if(len r > 0)
		remark(ctxt, r);
	return nil;
}

# ${tiles ...} - the same commands, with the result as the value rather
# than as a remark, so a script can ask tiles(2) a question.
runsbuiltin(ctxt: ref Context, nil: Sh,
		argv: list of ref Listnode): list of ref Listnode
{
	if((hd argv).word != "tiles")
		return nil;
	argv = tl argv;
	if(argv == nil)
		ctxt.fail("usage", "usage: ${tiles new WxH [scale] [title]}");
	w := (hd argv).word;
	if(w == "new")
		return ref Listnode(nil, string newhandle(ctxt, tl argv)) :: nil;
	if(!isnum(w))
		ctxt.fail("usage", "usage: ${tiles (new|<id> args...)}");
	h := ehandle(ctxt, w);
	rest := tl argv;
	if(rest == nil)
		ctxt.fail("usage", "usage: ${tiles <id> command...}");
	# The input verbs answer here too, and this is where a game loop
	# actually uses them: ks := ${tiles $id keys}.
	case (hd rest).word {
	"wait" =>
		ms := 0;
		if(tl rest != nil)
			ms = int (hd tl rest).word;
		return words(waitev(ctxt, h, ms));
	"keys" =>
		return words(readkeys(ctxt, h, 0));
	"pressed" =>
		return words(readkeys(ctxt, h, 1));
	"ms" =>
		# The clock, so a script can time itself - a frame rate on
		# the screen, or an answer to "how fast is this".
		return ref Listnode(nil, string sys->millisec()) :: nil;
	}
	# The answer IS the value here, error and all: a script asking
	# "size level" wants "256 96" back, and one asking something wrong
	# wants to see the "!" rather than have the script abort.
	return ref Listnode(nil, h.scr.cmd(concat(rest))) :: nil;
}

# The window this module adds and tiles(2) has no opinion about.  It is
# built the way sh-plot(1) builds its own - a frame, a panel inside it,
# an offscreen buffer bound with tk->putimage - because packing a panel
# straight under "." does not work.
newhandle(ctxt: ref Context, argv: list of ref Listnode): int
{
	if(argv == nil)
		ctxt.fail("usage", "usage: tiles new WxH [scale] [title]");
	(want, herr) := wxh((hd argv).word);
	if(herr != nil)
		ctxt.fail("usage", "tiles: " + herr);
	scale := 2;
	title := "tiles";
	argv = tl argv;
	if(argv != nil && isnum((hd argv).word)){
		scale = int (hd argv).word;
		argv = tl argv;
	}
	if(scale < 1 || scale > 8)
		ctxt.fail("usage", "tiles: silly scale");
	if(argv != nil)
		title = (hd argv).word;

	dc := ctxt.drawcontext;
	if(dc == nil)
		dc = tkclient->makedrawcontext();
	(top, nil) := tkclient->toplevel(dc, "", title, Tkclient->Appl);
	pw := want.x * scale;
	ph := want.y * scale;
	tkcmd(ctxt, top, "frame .f");
	tkcmd(ctxt, top, sys->sprint("panel .f.p -bd 0 -relief flat -width %d -height %d", pw, ph));
	tkcmd(ctxt, top, "pack .f.p -fill both -expand 1");
	tkcmd(ctxt, top, "pack .f -fill both -expand 1");

	chans := top.display.image.chans;
	buffer := top.display.newimage(Rect((0,0),(pw,ph)), chans, 0, Draw->Black);
	if(buffer == nil)
		ctxt.fail("tiles", "tiles: cannot allocate drawing buffer");
	scr := tiles->screen(top.display, chans, scale);
	if(scr == nil)
		ctxt.fail("tiles", "tiles: cannot make a screen");
	h := ref Handle(nexthandle++, top, buffer, scr, Point(pw, ph), 0,
		array[0] of string, array[0] of (int, int), nil, 0, 0, 0,
		nil, 0, 0);
	addhandle(h);
	return h.id;
}

# Put a named surface in the window.  A surface is drawn at the screen's
# scale already, so this is a blit and not a scale.
drawsurf(ctxt: ref Context, h: ref Handle, name: string): string
{
	im := h.scr.image(name);
	if(im == nil)
		return "!no surface " + name;
	show(ctxt, h);
	h.buffer.draw(h.buffer.r, im, nil, im.r.min);
	e := tk->putimage(h.top, ".f.p", h.buffer, nil);
	if(len e > 0 && e[0] == '!')
		ctxt.fail("tiles", "tiles: putimage: " + e);
	tkcmd(ctxt, h.top, "update");
	return nil;
}

# A surface to a file, so a script can build a screen and keep it
# without anyone looking at a window - a title card rendered by cron, or
# a check that wants to compare frames.  The format is the plainest
# thing that is not a guess: a line of "W H BYTESPERPIXEL", then the
# pixels as the display hands them over.
writesurf(ctxt: ref Context, h: ref Handle, name, path: string): string
{
	im := h.scr.image(name);
	if(im == nil)
		return "!no surface " + name;
	w := im.r.dx();
	ht := im.r.dy();
	bpp := im.depth / 8;
	b := array[w*ht*bpp] of byte;
	if(im.readpixels(im.r, b) < 0)
		return sys->sprint("!readpixels: %r");
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("!cannot create %s: %r", path);
	sys->fprint(fd, "%d %d %d\n", w, ht, bpp);
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("!cannot write %s: %r", path);
	return nil;
}

show(ctxt: ref Context, h: ref Handle)
{
	if(h.shown)
		return;
	h.shown = 1;
	tkcmd(ctxt, h.top, "update");
	# keyup as well as kbd, or keyhold(2) never sees a release and
	# every key a script binds sticks down.
	tkclient->startinput(h.top, "kbd" :: "keyup" :: "ptr" :: nil);
	tkclient->onscreen(h.top, nil);
}

wxh(s: string): (Point, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == 'x')
			return (Point(int s[0:i], int s[i+1:len s]), nil);
	return (Point(0, 0), "bad size " + s + ", want WxH");
}

ehandle(ctxt: ref Context, w: string): ref Handle
{
	h := gethandle(int w);
	if(h == nil)
		ctxt.fail("tiles", "tiles: no such handle " + w);
	return h;
}

hashslot(id: int): int
{
	return id % len handles;
}

addhandle(h: ref Handle)
{
	slot := hashslot(h.id);
	handles[slot] = h :: handles[slot];
}

gethandle(id: int): ref Handle
{
	for(hl := handles[hashslot(id)]; hl != nil; hl = tl hl)
		if((hd hl).id == id)
			return hd hl;
	return nil;
}

# As sh-plot(1) and sh-tk(1) both do: forget the handle and leave the
# window, because tkclient->wmctl(top, "exit") exits the whole process
# group and this module is a guest in whatever process runs the script.
delhandle(id: int)
{
	slot := hashslot(id);
	nl: list of ref Handle;
	for(hl := handles[slot]; hl != nil; hl = tl hl)
		if((hd hl).id != id)
			nl = hd hl :: nl;
	handles[slot] = nl;
}

isnum(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

concat(l: list of ref Listnode): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += (hd l).word;
	}
	return s;
}

remark(ctxt: ref Context, s: string)
{
	if(ctxt.options() & ctxt.INTERACTIVE)
		sys->print("%s\n", s);
}

tkcmd(ctxt: ref Context, top: ref Tk->Toplevel, s: string)
{
	e := tk->cmd(top, s);
	if(len e > 0 && e[0] == '!')
		ctxt.fail("tiles", "tiles: " + s + ": " + e);
}

# ------------------------------------------------------------- input
#
# The other half of a game: a script that can draw and cannot read is a
# picture.  This is keyhold(2) with a little language in front of it -
#
#	tiles $id bind left Left a A
#	tiles $id bind fire Space x
#	ks := ${tiles $id keys}
#
# - which is the same trade tiles(2)'s own commands make.  A script
# names its own actions, because what a key means is the script's
# business; nothing here knows what "fire" is.

# The keys a script can name that are not single characters.  Everything
# else is taken as itself, so "a" is a, and "Left" is the arrow.
keyname(s: string): int
{
	if(len s == 1)
		return s[0];
	case s {
	"Left" =>	return Keyboard->Left;
	"Right" =>	return Keyboard->Right;
	"Up" =>		return Keyboard->Up;
	"Down" =>	return Keyboard->Down;
	"Home" =>	return Keyboard->Home;
	"End" =>	return Keyboard->End;
	"Pgup" =>	return Keyboard->Pgup;
	"Pgdown" =>	return Keyboard->Pgdown;
	"Space" =>	return ' ';
	"Tab" =>	return '\t';
	"Enter" or "Return" =>	return '\n';
	"Esc" =>	return 16r1b;
	}
	return -1;
}

dobind(h: ref Handle, l: list of ref Listnode): string
{
	if(l == nil || tl l == nil)
		return "!usage: tiles <id> bind ACTION KEY...";
	act := (hd l).word;
	# the action's bit: an existing name keeps its bit, a new one takes
	# the next
	bit := -1;
	for(i := 0; i < len h.acts; i++)
		if(h.acts[i] == act)
			bit = i;
	if(bit < 0){
		if(len h.acts >= 30)
			return "!too many actions";
		a := array[len h.acts + 1] of string;
		a[0:] = h.acts;
		a[len h.acts] = act;
		h.acts = a;
		bit = len a - 1;
	}
	nb := h.binds;
	for(l = tl l; l != nil; l = tl l){
		k := keyname((hd l).word);
		if(k < 0)
			return "!no such key: " + (hd l).word;
		a := array[len nb + 1] of (int, int);
		a[0:] = nb;
		a[len nb] = (k, 1 << bit);
		nb = a;
	}
	h.binds = nb;
	h.kb = keyhold->mk(nb);
	return nil;
}

# Drain whatever the window has delivered since last time, fold it into
# the held set, and answer.  Non-blocking: a game loop asks once a frame
# and carries on, which is what a held-key set is for.
readkeys(ctxt: ref Context, h: ref Handle, edge: int): string
{
	if(h.kb == nil)
		return "";
	show(ctxt, h);
	# NOT `for(;;) alt{ ... * => break; }`.  A break in an alt arm
	# leaves the ALT, not the loop, so that spins for ever - which is
	# a trap this tree has written down (session(2)'s own notes) and
	# one I walked into anyway.  A flag is what ends the loop.
	drained := 0;
	while(!drained) alt{
	k := <-h.top.ctxt.kbd =>
		h.held = h.kb.key(h.held, k);
	* =>
		drained = 1;
	}
	set := h.held;
	if(edge){
		set = keyhold->edge(h.held, h.prev);
		h.prev = h.held;
	}
	s := "";
	for(i := 0; i < len h.acts; i++)
		if(set & (1 << i)){
			if(s != "")
				s += " ";
			s += h.acts[i];
		}
	return s;
}

# Frame pacing, against an absolute deadline rather than a fixed sleep -
# the same reason frameclock(2) exists for Limbo.  A shell loop that
# sleeps a fixed time runs at whatever rate the loop itself costs plus
# that, which is not a rate at all.
pace(h: ref Handle, ms: int)
{
	if(ms <= 0)
		return;
	now := sys->millisec();
	if(h.last == 0){
		h.last = now;
		return;
	}
	due := h.last + ms;
	if(due > now)
		sys->sleep(due - now);
	h.last = sys->millisec();
}

words(s: string): list of ref Listnode
{
	l: list of ref Listnode;
	(nil, w) := sys->tokenize(s, " ");
	for(; w != nil; w = tl w)
		l = ref Listnode(nil, hd w) :: l;
	rl: list of ref Listnode;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return rl;
}

# ------------------------------------------------------------ waiting
#
# A poll is not a wait, and a script that polls has to have a frame to
# hang the poll on.  Two ways to wait, and they are for different
# things.
#
# ${tiles $id wait [ms]} blocks until a key or, if ms is given, until ms
# have passed - whichever comes first - and answers "key ..." or "tick".
# It is one call, it is a real select, and it is what a game loop wants:
# the shell has no alt of its own, and this is Limbo doing the alt on
# its behalf.
#
# "tiles $id events NAME [ms]" is the other answer, and it is the more
# Inferno one: the same stream as a FILE in /chan, whose read blocks.
# Waiting is what a read does, so nothing new has to be invented; and
# because it is a file, another process can wait on it, a script can
# filter it through sed(1), and exporting the namespace exports the
# game's input.  What it costs is a process and the keyboard: once the
# server has it, "keys" and "wait" no longer see anything.

# The frame clock, made once per handle and shared by both waits.
ticker(h: ref Handle, ms: int): chan of int
{
	if(ms <= 0)
		return nil;
	if(h.tick != nil && h.tickms == ms)
		return h.tick;
	c := chan of int;
	if(fclock == nil)
		return nil;
	spawn fclock->tickms(c, ms);
	h.tick = c;
	h.tickms = ms;
	return c;
}

waitev(ctxt: ref Context, h: ref Handle, ms: int): string
{
	if(h.kb == nil)
		return "";
	if(h.served)
		return "!the event file owns the keyboard";
	show(ctxt, h);
	tc := ticker(h, ms);
	# A nil channel in an alt simply never fires, so no ms means wait
	# for a key and nothing else.
	for(;;) alt{
	k := <-h.top.ctxt.kbd =>
		h.held = h.kb.key(h.held, k);
		# Answer on a press, not on a release: a loop woken by
		# someone letting go of a key has nothing to do.
		if(h.held != 0)
			return "key " + heldnames(h);
	<-tc =>
		return "tick";
	}
}

heldnames(h: ref Handle): string
{
	s := "";
	for(i := 0; i < len h.acts; i++)
		if(h.held & (1 << i)){
			if(s != "")
				s += " ";
			s += h.acts[i];
		}
	return s;
}

# The same stream, as a file.  file2chan wants a directory served by the
# srv device and /chan in a bare namespace is an ordinary directory, so
# bind #s over it if it is not already - the same thing orchard(1) has
# to do.
events(ctxt: ref Context, h: ref Handle, name: string, ms: int): string
{
	if(h.kb == nil)
		return "!bind some keys first";
	if(h.served)
		return "!already serving";
	show(ctxt, h);
	fio := sys->file2chan("/chan", name);
	if(fio == nil){
		if(sys->bind("#s", "/chan", Sys->MREPL) < 0)
			return sys->sprint("!no /chan: %r");
		fio = sys->file2chan("/chan", name);
	}
	if(fio == nil)
		return sys->sprint("!cannot serve /chan/%s: %r", name);
	h.served = 1;
	spawn serve(h, fio, ticker(h, ms));
	return nil;
}

serve(h: ref Handle, fio: ref Sys->FileIO, tc: chan of int)
{
	pending: Sys->Rread;
	queued: list of string;
	for(;;) alt{
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		if(queued != nil){
			rc <-= (array of byte hd queued, nil);
			queued = tl queued;
		}else if(pending != nil)
			# Only one reader waits at a time here; a second is
			# told so rather than silently replacing the first.
			rc <-= (nil, "already a reader waiting");
		else
			pending = rc;
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	k := <-h.top.ctxt.kbd =>
		h.held = h.kb.key(h.held, k);
		if(h.held != 0)
			(pending, queued) = post(pending, queued,
				"key " + heldnames(h) + "\n");
	<-tc =>
		(pending, queued) = post(pending, queued, "tick\n");
	}
}

# An event goes to whoever is waiting, or waits itself.  The queue is
# bounded: a game that stops reading must not make the server eat memory
# holding key presses nobody will ever look at.
MAXQUEUE:	con 32;

post(pending: Sys->Rread, queued: list of string,
		ev: string): (Sys->Rread, list of string)
{
	if(pending != nil){
		pending <-= (array of byte ev, nil);
		return (nil, queued);
	}
	n := 0;
	for(l := queued; l != nil; l = tl l)
		n++;
	if(n >= MAXQUEUE)
		return (nil, queued);
	nq: list of string;
	for(l = queued; l != nil; l = tl l)
		nq = hd l :: nq;
	nq = ev :: nq;
	rl: list of string;
	for(; nq != nil; nq = tl nq)
		rl = hd nq :: rl;
	return (nil, rl);
}
