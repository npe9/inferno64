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
	h := ref Handle(nexthandle++, top, buffer, scr, Point(pw, ph), 0);
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
	tkclient->startinput(h.top, "kbd" :: "ptr" :: nil);
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
