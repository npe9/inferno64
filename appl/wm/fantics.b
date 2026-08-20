implement Fantics;

# Nelson coins "fantics" for something none of this session's other
# work-alikes touch: not a technology at all, but the *craft* of how
# information is staged for a person - pacing, emphasis, the dramatic
# pause - the same attention a theatre director gives a script, applied
# to what a screen shows and when. His point is that this is a real,
# neglected design discipline in its own right, not a frill layered on
# top of "real" computing.
#
# So the only honest work-alike is a literal staged performance: a
# script of timed "beats", each played back with real elapsed-time
# pacing, not just dumped to the screen at once. Three moves, deliberately
# not fifty - Nelson's own point is that a few well-chosen effects used
# with intent beat a kitchen sink of transitions used without it:
#
#   TYPE ms    reveal the beat's text one character at a time, ms
#              between characters - the oldest, plainest way to make
#              text feel like it's *happening* rather than just being
#              shown, and still the clearest demonstration that timing
#              itself is part of what's being communicated
#   FLASH ms   the text appears all at once, then holds for ms before
#              advancing - immediacy and emphasis, the opposite move
#              from TYPE, used where a typewriter crawl would undercut
#              the point rather than build to it
#   PAUSE ms   nothing on screen at all, for ms - the beat *is* the
#              silence; Nelson's dramatic pause taken completely
#              literally, not a transition between beats but a beat of
#              its own
#
# Runs as a bare wmclient window (no Tk - nothing here needs a button,
# and per wm/toycpu.b's finding this backend's synthetic clicks on Tk
# buttons aren't reliable anyway), black stage with light text rather
# than this tree's usual white background - the one app in this whole
# series actually about staging gets to look staged. Space/Return
# skips the current beat's animation (impatience - go straight to its
# fully-revealed state, or straight to the next beat if it's already
# there); r restarts from the first beat; q/Esc quits.
#
# usage: wm/fantics [script.fant]

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Fantics: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

MODETYPE, MODEFLASH, MODEPAUSE: con iota;

Beat: adt {
	mode:	int;
	param:	int;
	text:	string;
};

win: ref Window;
bg, fg, dim: ref Image;
bigfont, smallfont: ref Font;
beats: array of ref Beat;
idx: int;
elapsed: int;		# ms since the current beat started
skipped: int;		# this beat's animation was skipped ahead
scriptpath := "/lib/fantics/demo.fant";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil){
		sys->fprint(sys->fildes(2), "fantics: cannot load wmclient: %r\n");
		raise "fail:load";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	argv = tl argv;
	if(argv != nil)
		scriptpath = hd argv;

	win = wmclient->window(ctxt, "Fantics", Wmclient->Appl);
	d := win.display;
	bg = d.color(Draw->Black);
	fg = d.color(int 16rF0F0F0FF);
	dim = d.color(int 16r808080FF);
	bigfont = Font.open(d, "/fonts/vera/verabd/verabd.20.font");
	if(bigfont == nil)
		bigfont = Font.open(d, "*default*");
	smallfont = Font.open(d, "/fonts/lucidasans/unicode.8.font");
	if(smallfont == nil)
		smallfont = bigfont;

	(b, err) := loadscript(scriptpath);
	if(b == nil){
		sys->fprint(sys->fildes(2), "fantics: %s: %s\n", scriptpath, err);
		raise "fail:load";
	}
	beats = b;

	win.reshape(Rect((0, 0), (720, 380)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			frame();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		dokey(k);
	<-ticks =>
		if(idx < len beats){
			elapsed += 33;
			frame();
		}
	}
}

dokey(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'r' or 'R' =>
		idx = 0;
		elapsed = 0;
		skipped = 0;
	' ' or '\n' or '\r' =>
		advanceorskip();
	}
	frame();
}

advanceorskip()
{
	if(idx >= len beats)
		return;
	b := beats[idx];
	if(b.mode == MODETYPE && !skipped){
		skipped = 1;	# jump straight to fully revealed, don't advance yet
		return;
	}
	idx++;
	elapsed = 0;
	skipped = 0;
}

# Called every tick: decides whether the current beat's timer has run
# out and it's time to move on, purely from elapsed-ms bookkeeping -
# the actual on-screen reveal amount is recomputed fresh in frame().
frame()
{
	img := win.image;
	if(img == nil)
		return;
	if(idx >= len beats){
		drawstage("", "the end - r to restart, q to quit");
		return;
	}
	b := beats[idx];
	case b.mode {
	MODETYPE =>
		nchars := len b.text;
		if(!skipped)
			nchars = elapsed/b.param;
		if(nchars > len b.text)
			nchars = len b.text;
		if(nchars >= len b.text && elapsed > len(b.text)*b.param + 800){
			advance();
			return;
		}
		drawstage(b.text[0:nchars], "space=skip  r=restart  q=quit");
	MODEFLASH =>
		if(elapsed > b.param){
			advance();
			return;
		}
		drawstage(b.text, "space=next  r=restart  q=quit");
	MODEPAUSE =>
		if(elapsed > b.param){
			advance();
			return;
		}
		drawstage("", "");
	}
}

advance()
{
	idx++;
	elapsed = 0;
	skipped = 0;
}

drawstage(text: string, hint: string)
{
	img := win.image;
	img.draw(img.r, bg, nil, Point(0, 0));
	(nil, lines) := sys->tokenize(text, "\n");
	y := img.r.min.y + img.r.dy()/3;
	for(l := lines; l != nil; l = tl l){
		img.text(Point(img.r.min.x+24, y), fg, Point(0, 0), bigfont, hd l);
		y += bigfont.height + 6;
	}
	if(hint != "")
		img.text(Point(img.r.min.x+24, img.r.max.y-24), dim, Point(0, 0), smallfont, hint);
	img.flush(Draw->Flushnow);
}

# --- loading ---

loadscript(path: string): (array of ref Beat, string)
{
	(src, err) := readfile(path);
	if(src == nil)
		return (nil, err);

	blist: list of ref Beat;
	cur: ref Beat;
	curlines: list of string;

	(nil, srclines) := sys->tokenize(src, "\n");
	for(sl := srclines; sl != nil; sl = tl sl){
		line := hd sl;
		if(cur == nil){
			if(len line == 0 || line[0] == '#')
				continue;
			(n, toks) := sys->tokenize(line, " \t");
			if(n < 1)
				continue;
			mode := -1;
			case hd toks {
			"TYPE" =>	mode = MODETYPE;
			"FLASH" =>	mode = MODEFLASH;
			"PAUSE" =>	mode = MODEPAUSE;
			}
			if(mode < 0)
				continue;
			param := 200;
			if(n >= 2)
				param = int hd tl toks;
			if(param <= 0)
				param = 1;
			cur = ref Beat(mode, param, "");
			curlines = nil;
		}else if(line == "END"){
			s := "";
			for(cl := revstrs(curlines); cl != nil; cl = tl cl){
				if(s != "")
					s += "\n";
				s += hd cl;
			}
			cur.text = s;
			blist = cur :: blist;
			cur = nil;
		}else
			curlines = line :: curlines;
	}
	blist = revbeats(blist);
	arr := array[lenbeats(blist)] of ref Beat;
	i := 0;
	for(b := blist; b != nil; b = tl b){
		arr[i] = hd b;
		i++;
	}
	return (arr, nil);
}

revstrs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

lenbeats(l: list of ref Beat): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

revbeats(l: list of ref Beat): list of ref Beat
{
	r: list of ref Beat;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return (nil, "not a regular file: "+path);
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (string a[0:n], nil);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
