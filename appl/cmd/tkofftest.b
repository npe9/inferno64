implement Tkofftest;

# Render Tk widgets into an image of our own and read back what they drew.
#
# On screen this cannot be done: under the Metal present path
# Image.readpixels returns 00 00 00 both for a window on the display's
# screen and for display.image itself, so what a widget actually put on
# the page is invisible to the program that drew it.  That leaves every
# change to the window system checkable only by looking at it, against a
# working agreement that asks for in-process evidence.
#
# A Tk toplevel does not have to be given the display's screen.  Allocate
# a Screen over an ordinary image, make a window in it, and hand the
# toplevel that window under the request id tkclient uses when there is no
# window manager - "-1".  Tk then draws into memory, where readpixels
# works, and a test can measure the result.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Screen: import draw;
include "tk.m";
	tk: Tk;
include "titlebar.m";
	titlebar: Titlebar;
include "tklayout.m";
	tklayout: Tklayout;
	Problem: import tklayout;
include "wmclient.m";
include "tkclient.m";
	tkclient: Tkclient;

# ttffs(4) serves TrueType files from /fonts/ttf as Inferno subfonts at
# any size.  It wants a draw context, but only for its display, so this
# test can give it one and check the antialiased path without a window
# manager or a running window system.
Ttffs: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Tkofftest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 900;			# room for the widest widget at the largest font,
H: con 700;			# so that packing is never what clamps a measurement

off: ref Image;
win: ref Image;
scr: ref Screen;
disp: ref Display;

ok := 0;
fail := 0;

small := "";		# two fonts, 15 pixels high and 30
large := "";

servedttf := 0;		# this test started ttffs, so this test stops it

report(good: int, what: string)
{
	if(good){
		ok++;
		sys->print("OK   %s\n", what);
	}else{
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

# distinct values in the pane, and how many pixels are not the background
scan(): (int, int)
{
	n := W*H;
	b := array[n*3] of byte;
	off.readpixels(off.r, b);
	seen := array[256] of {* => 0};
	ink := 0;
	for(i := 0; i < n*3; i += 3){
		v := int b[i];
		seen[v] = 1;
		if(v != 255)
			ink++;
	}
	d := 0;
	for(i = 0; i < 256; i++)
		if(seen[i])
			d++;
	return (d, ink);
}

blank()
{
	off.draw(off.r, disp.color(Draw->White), nil, off.r.min);
}

# a toplevel drawing into our own image rather than the display's screen
offscreen(): ref Tk->Toplevel
{
	top := tk->toplevel(disp, "");
	if(top == nil)
		return nil;
	top.screenr = off.r;
	return top;
}

# hand the toplevel its image, under the request id tkclient uses when
# there is no window manager.  Do it after the widgets exist: Tk paints
# what it has when the image arrives.
map(top: ref Tk->Toplevel): int
{
	if((e := tk->putimage(top, ". -1", win, nil)) != nil && len e > 0){
		sys->print("putimage: %s\n", e);
		return 0;
	}
	tk->cmd(top, "update");
	return 1;
}

WIDGETS: con 6;

# one representative dialog, per font: the sizes it reports are the
# question - a toolkit that measures its font grows all of them
dialog(top: ref Tk->Toplevel, font: string): array of Point
{
	# every one of these sizes itself to the text it holds.  Widgets
	# configured in character units instead - an entry's -width, a text
	# widget's -width and -height - are reported below but not asserted
	# on, because their size is meant not to follow the font.
	spec := array[] of {
		".l label .l -text {Handgloves 123}",
		".b button .b -text {Cancel}",
		".c checkbutton .c -text {Wrap lines}",
		".r radiobutton .r -text {Every third}",
		".m menubutton .m -text {File}",
		".s scale .s -orient horizontal",
	};
	sz := array[WIDGETS] of Point;
	for(i := 0; i < WIDGETS; i++){
		s := spec[i];
		for(j := 0; j < len s; j++)
			if(s[j] == ' '){
				nm := s[0:j];
				e := tk->cmd(top, s[j+1:] + " -font " + font);
				if(len e > 0 && e[0] == '!'){
					sys->print("  %s: %s\n", nm, e);
					return nil;
				}
				tk->cmd(top, "pack " + nm);
				break;
			}
	}
	if(!map(top))
		return nil;
	# in pixels: -actwidth on an entry or a text is in characters and
	# rows, so it cannot answer whether the widget grew on the page
	for(i = 0; i < WIDGETS; i++){
		s := spec[i];
		for(j := 0; j < len s; j++)
			if(s[j] == ' '){
				r := tk->rect(top, s[0:j], 0);
				sz[i] = Point(r.dx(), r.dy());
				break;
			}
	}
	return sz;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	titlebar = load Titlebar Titlebar->PATH;
	if(titlebar != nil)
		titlebar->init();
	tklayout = load Tklayout Tklayout->PATH;
	if(tklayout != nil)
		tklayout->init();
	if(tk == nil){
		sys->print("FAIL no tk: %r\n");
		raise "fail:no tk";
	}
	disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("FAIL no display: %r\n");
		raise "fail:no display";
	}
	off = disp.newimage(Rect((0,0),(W,H)), Draw->RGB24, 0, Draw->White);
	scr = Screen.allocate(off, disp.color(Draw->White), 0);
	if(off == nil || scr == nil){
		sys->print("FAIL no offscreen screen: %r\n");
		raise "fail:no screen";
	}
	win = scr.newwindow(off.r, Draw->Refbackup, Draw->Nofill);
	if(win == nil){
		sys->print("FAIL no offscreen window: %r\n");
		raise "fail:no window";
	}

	startttf();

	# The control first: an untouched pane must read back as nothing at
	# all.  Without it, "the widget drew" cannot be told from "the
	# readback returns rubbish that happens to vary".
	blank();
	(lv, ink) := scan();
	report(lv == 1 && ink == 0,
		sys->sprint("a blank pane reads back blank (%d levels, %d inked)", lv, ink));

	# and the same pane with a widget on it must not
	blank();
	top := offscreen();
	if(top == nil){
		sys->print("FAIL no offscreen toplevel\n");
		raise "fail:no toplevel";
	}
	tk->cmd(top, "label .l -text {Handgloves 123} -bg white -fg black");
	tk->cmd(top, "pack .l");
	map(top);
	(lv, ink) = scan();
	report(ink > 0 && lv > 1,
		sys->sprint("a widget's own pixels read back (%d levels, %d inked)", lv, ink));

	# Does the toolkit measure its font, or assume a cell?  Two fonts
	# from this tree, 15 and 30 pixels high, no TrueType needed.
	small = "/fonts/lucidasans/unicode.8.font";
	large = "/fonts/pelm/ascii.16.font";
	blank();
	t1 := offscreen();
	s1 := dialog(t1, small);
	blank();
	t2 := offscreen();
	s2 := dialog(t2, large);
	if(s1 == nil || s2 == nil)
		report(0, "the dialog builds at both fonts");
	else{
		grew := 0;
		names := array[] of {"label", "button", "checkbutton",
			"radiobutton", "menubutton", "scale"};
		for(i := 0; i < WIDGETS; i++){
			sys->print("     %-12s %3dx%-3d -> %3dx%-3d\n",
				names[i], s1[i].x, s1[i].y, s2[i].x, s2[i].y);
			if(s2[i].y > s1[i].y && s2[i].x >= s1[i].x)
				grew++;
		}
		report(grew == WIDGETS,
			sys->sprint("every widget grows with the font (%d of %d)",
				grew, WIDGETS));
	}

	# The titlebar is drawn on every window there is, so it is the one
	# layout worth checking by name.  Its buttons are fixed-size bitmaps
	# and its title is text: a taller font must not push the title into
	# the buttons, and nothing may leave the pane.
	checktitlebar(small, "the tree's own font");
	checktitlebar(large, "a font twice as tall");

	checkdefault();
	checklayout();

	# If a TrueType face is being served, say whether Tk antialiases.
	# A bitmap font can only ever put two values on the page.
	ttf := "/mnt/ft/" + ttfname();
	if(ttf != "/mnt/ft/"){
		blank();
		t3 := offscreen();
		e := tk->cmd(t3, "label .l -text {Handgloves 123} -bg white -fg black -font " + ttf);
		if(len e > 0 && e[0] == '!')
			sys->print("     no TrueType face served (%s); skipped\n", e);
		else{
			tk->cmd(t3, "pack .l");
			map(t3);
			(lv, ink) = scan();
			report(lv > 2, sys->sprint(
				"Tk antialiases a TrueType face (%s: %d levels)", ttf, lv));
		}
	}else
		sys->print("     nothing served under /mnt/ft; antialiasing not checked\n");

	# If this test started the font server, take it down again: its Styx
	# loop never returns, and emu does not exit while it is running.
	if(servedttf)
		sys->unmount(nil, "/mnt/ft");

	sys->print("tkofftest: %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:tkofftest";
}

# Serve whatever TrueType files are in /fonts/ttf, if any and if ttffs
# is built.  Silent when there are none: this tree ships no .ttf.
startttf()
{
	if(sys->open("/mnt/ft/index", Sys->OREAD) != nil)
		return;			# somebody is already serving
	if((fd := sys->open("/fonts/ttf", Sys->OREAD)) == nil)
		return;
	(n, nil) := sys->dirread(fd);
	if(n <= 0)
		return;
	tf := load Ttffs "/dis/ttffs.dis";
	if(tf == nil)
		return;
	sys->create("/mnt", Sys->OREAD, Sys->DMDIR|8r777);
	sys->create("/mnt/ft", Sys->OREAD, Sys->DMDIR|8r777);
	spawn tf->init(ref Draw->Context(disp, nil, nil), "ttffs" :: nil);
	for(i := 0; i < 40; i++){
		if(sys->open("/mnt/ft/index", Sys->OREAD) != nil){
			servedttf = 1;
			return;
		}
		sys->sleep(100);
	}
}

# Every real program builds its window with tkclient->toplevel, not with
# tk->toplevel, so "emu -f sets the font for every widget" is a claim about
# that path and not about this test's own.  tkclient connects to a window
# manager and builds a titlebar before it gets to a widget; if it named a
# font of its own anywhere along the way, the -f default would reach a bare
# toplevel and miss every actual window.  Ask both, and require the same
# answer.
checkdefault()
{
	if(tkclient == nil){
		sys->print("     no tkclient module; the real toplevel path not checked\n");
		return;
	}
	tkclient->init();
	blank();
	bare := offscreen();
	if(bare == nil)
		return;
	tk->cmd(bare, "label .l -text {Handgloves 123} -bg white -fg black");
	barefont := tk->cmd(bare, ".l cget -font");

	blank();
	(top, nil) := tkclient->toplevel(ref Draw->Context(disp, nil, nil), "", "Default", Tkclient->Appl);
	if(top == nil){
		report(0, "a tkclient toplevel builds offscreen");
		return;
	}
	top.screenr = off.r;
	tk->cmd(top, "label .l -text {Handgloves 123} -bg white -fg black");
	tk->cmd(top, "pack .l");
	realfont := tk->cmd(top, ".l cget -font");
	report(realfont == barefont && len realfont > 0 && realfont[0] != '!', sys->sprint(
		"a real (tkclient) window inherits the same default font (%s)", realfont));

	# and, when that default is a served TrueType face, it is really
	# antialiased on the page and not merely named
	map(top);
	(lv, ink) := scan();
	if(len realfont > len "/mnt/ft/" && realfont[0:len "/mnt/ft/"] == "/mnt/ft/")
		report(lv > 2, sys->sprint(
			"the default TrueType face is antialiased in a real window (%d levels, %d inked)",
			lv, ink));
	else
		sys->print("     default font is %s: bitmap, so %d levels is right\n",
			realfont, lv);
}

# The failure a bigger font actually causes is not a mis-sized widget -
# libtk sizes those from the font, asserted above - but a window whose
# pixels were counted out around the old size and no longer holds its
# contents.  Tk clips rather than overflows, so the widget rectangles all
# still look reasonable; what gives it away is the room a widget asked
# for against the room it got.  tklayout(2) does that walk.
checklayout()
{
	if(tklayout == nil){
		sys->print("     no tklayout module; layouts not checked\n");
		return;
	}

	# A checker that has never been seen to report anything has not been
	# shown to look at anything, so the positive control comes first:
	# the same dialog, at the same font, in a pane far too small for it.
	# It must name the widgets that lost room.
	tight := scr.newwindow(Rect((0,0),(140,40)), Draw->Refbackup, Draw->Nofill);
	if(tight == nil){
		report(0, "a small pane can be allocated for the layout control");
		return;
	}
	blank();
	squashed := tk->toplevel(disp, "");
	if(squashed == nil)
		return;
	squashed.screenr = Rect((0,0),(140,40));
	tk->cmd(squashed, "label .l -text {Handgloves 123} -font " + large);
	tk->cmd(squashed, "button .b -text {Cancel} -font " + large);
	tk->cmd(squashed, "pack .l");
	tk->cmd(squashed, "pack .b");
	tk->putimage(squashed, ". -1", tight, nil);
	tk->cmd(squashed, "update");
	bad := tklayout->check(squashed, ".");
	n := 0;
	for(l := bad; l != nil; l = tl l)
		if((hd l).kind == Tklayout->Clipped){
			n++;
			sys->print("     control: %s\n", (hd l).text());
		}
	report(n > 0, sys->sprint(
		"the layout checker names widgets that lost room (%d of 2)", n));
	if(n == 0)
		return;			# it cannot vouch for anything below

	# The negative half: the same two widgets with room to spare must
	# come back clean, or the checker is merely always complaining.
	blank();
	roomy := offscreen();
	if(roomy == nil)
		return;
	tk->cmd(roomy, "label .l -text {Handgloves 123} -font " + large);
	tk->cmd(roomy, "button .b -text {Cancel} -font " + large);
	tk->cmd(roomy, "pack .l");
	tk->cmd(roomy, "pack .b");
	map(roomy);
	good := tklayout->check(roomy, ".");
	for(l = good; l != nil; l = tl l)
		sys->print("     %s\n", (hd l).text());
	report(good == nil, "the same widgets with room to spare come back clean");

	# and now the chrome every window has, at both fonts.  A fault here
	# would be a real bug.
	for(i := 0; i < 2; i++){
		font := small;
		what := "the tree's own font";
		if(i == 1){
			font = large;
			what = "a font twice as tall";
		}
		blank();
		top := offscreen();
		if(top == nil || titlebar == nil)
			return;
		tk->cmd(top, ". configure -font " + font);
		titlebar->new(top, Titlebar->Appl);
		titlebar->settitle(top, "A Window With Quite A Long Title Indeed");
		map(top);
		probs := tklayout->check(top, ".Wm_t");
		for(l = probs; l != nil; l = tl l)
			sys->print("     %s\n", (hd l).text());
		report(probs == nil, sys->sprint(
			"no titlebar widget is short of room in %s", what));
	}
}

# the real titlebar, built by the real code, measured
checktitlebar(font, what: string)
{
	if(titlebar == nil){
		sys->print("     no titlebar module; chrome not checked\n");
		return;
	}
	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, ". configure -font " + font);
	titlebar->new(top, Titlebar->Appl);
	titlebar->settitle(top, "A Window With Quite A Long Title Indeed");
	map(top);
	title := tk->rect(top, ".Wm_t.title", 0);
	bar := tk->rect(top, ".Wm_t", 0);
	# the leftmost button, whichever buttons this configuration has
	buts := array[] of {".Wm_t.e", ".Wm_t.m", ".Wm_t.h", ".Wm_t.ok", ".Wm_t.top"};
	leftmost := 1000000;
	nb := 0;
	for(i := 0; i < len buts; i++){
		r := tk->rect(top, buts[i], 0);
		if(r.dx() == 0 && r.dy() == 0)
			continue;
		nb++;
		if(r.min.x < leftmost)
			leftmost = r.min.x;
		if(r.max.x > W || r.max.y > H)
			leftmost = -1;		# off the pane
	}
	good := nb > 0 && title.max.x <= leftmost && bar.max.x <= W && bar.max.y <= H;
	report(good, sys->sprint(
		"the titlebar holds together in %s (title ends %d, %d buttons from %d, bar %dx%d)",
		what, title.max.x, nb, leftmost, bar.dx(), bar.dy()));

	# The minimum size a window may be resized to must be at least its
	# own titlebar.  Measured from the buttons alone - fixed-size
	# bitmaps - it is short by however much the title's text is taller,
	# which is one pixel at the 8-pixel font and twelve at a 32-pixel
	# one.  This is the check that catches that.
	ms := titlebar->minsize(top);
	bb := tk->rect(top, ".Wm_t", Tk->Border);
	report(ms.y >= bb.dy(), sys->sprint(
		"a window cannot be shorter than its titlebar in %s (minsize %d, bar %d)",
		what, ms.y, bb.dy()));
}

# first face ttffs is serving, if any, at a middling size
ttfname(): string
{
	fd := sys->open("/mnt/ft/index", Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[8192] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	s := string b[0:n];
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\n')
			return s[0:i] + ".r.16.font";
	return "";
}
