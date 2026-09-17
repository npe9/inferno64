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
include "wmtheme.m";
	wmtheme: Wmtheme;
include "tknotebook.m";
	tknotebook: Tknotebook;
	Notebook: import tknotebook;
include "keyboard.m";
include "tkspinbox.m";
	tkspinbox: Tkspinbox;
	Spinbox: import tkspinbox;
include "wmclient.m";
include "tkclient.m";
	tkclient: Tkclient;
include "env.m";
include "math.m";
	math: Math;

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
huge := "";		# and a third, if one is served, to reach scale 3

servedttf := 0;		# this test started ttffs, so this test stops it

butsz := array[3] of {* => 0};		# chrome button size, per font
butink := array[3] of {* => 0.0};	# and how much of it is inked
nchrome := 0;

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
	wmtheme = load Wmtheme Wmtheme->PATH;
	if(wmtheme != nil)
		wmtheme->init();
	tknotebook = load Tknotebook Tknotebook->PATH;
	tkspinbox = load Tkspinbox Tkspinbox->PATH;
	math = load Math Math->PATH;
	if(tknotebook != nil)
		tknotebook->init();
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
	if((tn0 := ttfname()) != "")
		huge = "/mnt/ft/" + tn0[0:len tn0 - len ".r.16.font"] + ".r.32.font";
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
	if(huge != "")
		checktitlebar(huge, "a font four times as tall");

	checkdefault();
	checklayout();
	checkfocusring();
	checkstyle();
	checkstyleenv();
	checkbevelhue();
	checkscene();
	checkelide();
	checkcontrast();
	checkmenu();
	checkhover();
	checkfocusall();
	checkcolourwidth();
	checkcanvastag();
	checkplaintitle();
	checktheme();
	checknotebook();
	checkspinbox();
	checkvoice();

	# The chrome's artwork is 16-pixel bitmaps in /icons/tk, and libtk
	# resolves a bare -bitmap name straight there, so without help the
	# buttons stay one size while the bar around them follows the font.
	# Before titlebar(2) scaled them this read 20x20 at both fonts.
	if(nchrome >= 2){
		grew := "";
		for(g := 0; g < nchrome; g++)
			grew += sys->sprint(" %d", butsz[g]);
		report(butsz[1] > butsz[0] && (nchrome < 3 || butsz[2] > butsz[1]),
			sys->sprint("the titlebar's artwork grows with the font (%s )", grew));
		# and it is the same picture, not a broken one: a whole-number
		# scale replicates pixels, so the proportion inked is kept.
		d := butink[1] - butink[0];
		if(d < 0.0)
			d = -d;
		report(butink[0] > 0.0 && d < 0.10, sys->sprint(
			"and is still the same picture (%d%% inked against %d%%)",
			int(butink[0]*100.0), int(butink[1]*100.0)));
	}

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
	# Classic explicitly.  What this measures is titlebar(2)'s ARTWORK -
	# 16-pixel bitmaps replicated at a whole-number scale, so the
	# proportion inked is preserved.  Under the flat style a widget's
	# border width is derived from the font as well, so a button's ink
	# includes a border that scaled by a different factor from the
	# bitmap, and the proportion moves for a reason that has nothing to
	# do with the artwork: 44% against 61%.  The property is still true
	# of the picture; the measurement stops being about the picture.
	tk->cmd(top, "style classic");
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
	# The chrome's own proportions, reported rather than asserted: the bar
	# and the title follow the font, and the buttons are fixed-size
	# bitmaps out of /icons/tk, so the gap between them is what a bigger
	# font opens up.
	# The chrome's own proportions.  The bar and the title follow the
	# font; the artwork in the buttons is fixed-size unless titlebar(2)
	# scales it, so this is where that shows.
	e := tk->rect(top, ".Wm_t.e", Tk->Border);
	ink := inkfraction(e);
	sys->print("     %-22s bar %dx%d, title h %d, button %dx%d, %d%% inked\n",
		what, bar.dx(), bar.dy(), title.dy(), e.dx(), e.dy(), int(ink*100.0));
	if(nchrome < len butsz){
		butsz[nchrome] = e.dx();
		butink[nchrome] = ink;
		nchrome++;
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

# A notebook made out of the widgets libtk already has - the plan's claim
# that the cheap half of the missing widget set is composition in Limbo.
# What makes it a notebook rather than three frames is that exactly one
# page is laid out at a time, so that is what this checks, through the
# same winfo the layout checker uses.
# tkspinbox(2): an entry with an up and a down beside it.  Two things are
# worth checking and they fail separately.
#
# That it spins, and stops at the ends of its range - a spinbox that runs
# past its limits is worse than none, because a caller has no reason to
# check.
#
# And that it SAYS the new number.  The entry announces itself on arrival
# for free, since libtk knows an entry is a control with a state; nothing
# announces a value a button changed, because nothing typed into it.
# That is the exact shape of the choicebutton bug found earlier in this
# session - right on arrival, silent on change - so it is checked here
# rather than assumed to have been learned.
# An application's event loop, in miniature: the spinbox's buttons and
# arrow keys report on a channel and something has to act on what
# arrives.  The ack is so the test can tell when the value has moved
# without sleeping and hoping.
pump(sb: ref Spinbox, c: chan of string, acked: chan of int)
{
	for(;;){
		s := <-c;
		sb.event(s);
		acked <-= 1;
	}
}

checkspinbox()
{
	if(tkspinbox == nil){
		sys->print("     no tkspinbox module; not checked\n");
		return;
	}
	tkspinbox->init();
	# Before anything spins: the module opens the voice device when it
	# first has something to say, so a bind that arrives later is a
	# different test than the one meant here.
	sys->bind("#V", "/dev", Sys->MAFTER);
	blank();
	top := offscreen();
	if(top == nil)
		return;
	(sb, sc) := tkspinbox->new(top, ".s", 0, 10, 2, 4);
	if(sb == nil){
		report(0, "a spinbox builds");
		return;
	}
	tk->cmd(top, "pack .s");
	map(top);

	start := sb.value();
	up := sb.event("up");
	down := sb.event("down");
	report(start == 4 && up == 6 && down == 4, sys->sprint(
		"a spinbox starts where it was put and steps by its step (%d, %d, %d)",
		start, up, down));

	for(i := 0; i < 20; i++)
		sb.event("up");
	hi := sb.value();
	for(i = 0; i < 20; i++)
		sb.event("down");
	lo := sb.value();
	report(hi == 10 && lo == 0, sys->sprint(
		"and stops at both ends of its range (%d and %d)", hi, lo));

	report(sb.event("sideways") == 0, "and ignores a string it does not know");

	# The arrow keys, driven for real rather than inspected.  tk->keyboard()
	# hands a key straight to the toplevel, so this is the same path a
	# person's keypress takes, binding and all.  It needs a pump: the
	# binding does `send' on the channel and nothing would be receiving,
	# so the send - and with it tk->keyboard() - would block forever.
	# That is what an application's event loop is, so the test grows one.
	acked := chan of int;
	spawn pump(sb, sc, acked);
	sb.set(4);
	tk->cmd(top, "focus .s.e");
	tk->cmd(top, "update");
	tk->keyboard(top, Keyboard->Up);
	<-acked;
	bykey := sb.value();
	tk->keyboard(top, Keyboard->Down);
	<-acked;
	tk->keyboard(top, Keyboard->Down);
	<-acked;
	bykey2 := sb.value();
	report(bykey == 6 && bykey2 == 2, sys->sprint(
		"and the arrow keys spin it too (%d up, then %d after two down)",
		bykey, bykey2));

	# what it says when it moves
	sfd := sys->open("/dev/voice/screen", Sys->OREAD);
	if(sfd == nil){
		sys->print("     no /dev/voice; the spinbox announcement not checked\n");
		return;
	}
	# A fresh spinbox in a fresh toplevel.  Run against the one above it
	# reported nothing at all: that one has the keyboard, having just been
	# driven by it, and voice(3) throws queued announcements away when the
	# focus moves - so what this measured depended on which checks ran
	# before it.  A check whose result depends on its neighbours is not
	# measuring what it says it is.
	blank();
	t2 := offscreen();
	if(t2 == nil)
		return;
	# Numbers no earlier check in this function has said.  voice(3)
	# deliberately drops an announcement identical to the last one it
	# queued - a screen reader that repeats itself is tiring - and the
	# checks above end by saying "2", so a spinbox that also stepped to 2
	# was correctly silent and this read as a failure of the spinbox.
	# Draining the queue does not help: what is remembered is the last
	# thing QUEUED, not the last thing still waiting.
	(sb2, nil) := tkspinbox->new(t2, ".s", 100, 200, 7, 100);
	if(sb2 == nil)
		return;
	tk->cmd(t2, "pack .s");
	map(t2);
	drain(sfd);
	sb2.event("up");
	said := next(sfd);
	report(said == "107", sys->sprint(
		"and says the number it moved to (%#q)", said));

	# at the end of the range nothing moves, so nothing should be said -
	# a person leaning on the button should not hear the same number over
	# and over
	sb2.set(200);
	drain(sfd);
	sb2.event("up");
	quiet := waiting();
	report(quiet == 0, sys->sprint(
		"and says nothing when it did not move (%d waiting)", quiet));
}

checknotebook()
{
	if(tknotebook == nil){
		sys->print("     no tknotebook module; not checked\n");
		return;
	}
	blank();
	top := offscreen();
	if(top == nil)
		return;
	nb := tknotebook->new(top, ".nb",
		array[] of {"General", "Fonts", "Advanced"});
	if(nb == nil){
		report(0, "a notebook can be made");
		return;
	}
	for(i := 0; i < 3; i++)
		tk->cmd(top, sys->sprint("label %s.l -text {page %d}",
			nb.page(i), i));
	for(i = 0; i < 3; i++)
		tk->cmd(top, "pack " + nb.page(i) + ".l");
	tk->cmd(top, "pack .nb -fill both -expand 1");
	map(top);

	report(shown(top, nb) == "0", sys->sprint(
		"a notebook lays out one page, the first (%s)", shown(top, nb)));

	nb.select(2);
	tk->cmd(top, "update");
	report(shown(top, nb) == "2", sys->sprint(
		"and selecting a tab swaps which one (%s)", shown(top, nb)));

	# it is made of real widgets, so it follows the font like the rest
	small1 := tk->rect(top, ".nb.tabs", Tk->Border).dy();
	tk->cmd(top, ".nb.tabs.t0 configure -font " + large);
	tk->cmd(top, ".nb.tabs.t1 configure -font " + large);
	tk->cmd(top, ".nb.tabs.t2 configure -font " + large);
	tk->cmd(top, "update");
	large1 := tk->rect(top, ".nb.tabs", Tk->Border).dy();
	report(large1 > small1, sys->sprint(
		"and its tabs grow with the font (%d -> %d)", small1, large1));
}

# which pages a geometry manager has, as a string of indices
shown(top: ref Tk->Toplevel, nb: ref Notebook): string
{
	o := "";
	for(i := 0; i < len nb.tabs; i++)
		if(tk->cmd(top, "winfo manager " + nb.page(i)) != "")
			o += string i;
	return o;
}

# Which control has the keyboard, shown on the page.
#
# libtk draws a ring for it, and the two lines that do so were live in
# label.c and commented out in buton.c - so a label showed its focus and
# a button, which is what a person tabs between, did not.  The reader
# says where you are; the screen should agree.
checkfocusring()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, "button .b -text {Save}");
	tk->cmd(top, "button .other -text {Save}");
	tk->cmd(top, "pack .b");
	tk->cmd(top, "pack .other");
	map(top);
	# tkhaskeyfocus() is false unless the toplevel itself has the
	# keyboard - top->focused - which an offscreen window never gets by
	# itself.  Without this the ring is correctly never drawn and the
	# check fails for a reason that has nothing to do with what it is
	# testing, which is what it did first time out.
	tk->cmd(top, "focus -global 1");

	r := tk->rect(top, ".b", Tk->Border);
	tk->cmd(top, "focus .other");
	tk->cmd(top, "update");
	away := ink(r);
	tk->cmd(top, "focus .b");
	tk->cmd(top, "update");
	held := ink(r);

	# Two identical buttons, so the only difference between the two
	# readings is which one has the keyboard.
	report(held != away, sys->sprint(
		"a focused button looks different from an unfocused one (%d inked against %d)",
		held, away));
}



# Nothing in the tree asks for the flat style by name, so the way anyone
# will actually meet it is $tkstyle: tkclient(2) reads it and every
# program that builds its window that way follows, with no program
# edited.  This checks the wire rather than the look - that the variable
# reaches a real tkclient toplevel, and that unset still means classic,
# which is the half that matters if the taste question is ever settled
# the other way.
checkstyleenv()
{
	if(tkclient == nil)
		return;
	e := load Env Env->PATH;
	if(e == nil){
		sys->print("     no env module; $tkstyle not checked\n");
		return;
	}
	# tkclient caches the answer on first use, so this has to run in a
	# fresh instance of it or it would only ever see the first setting.
	got := array[2] of string;
	want := array[2] of {"classic", "flat"};
	for(i := 0; i < 2; i++){
		e->setenv("tkstyle", want[i]);
		tc := load Tkclient Tkclient->PATH;
		if(tc == nil)
			return;
		tc->init();
		blank();
		(top, nil) := tc->toplevel(ref Draw->Context(disp, nil, nil),
			"", "Style", Tkclient->Appl);
		if(top == nil){
			report(0, "a tkclient toplevel builds offscreen");
			return;
		}
		top.screenr = off.r;
		got[i] = tk->cmd(top, "style");
	}
	e->setenv("tkstyle", "");
	report(got[0] == "classic", sys->sprint(
		"$tkstyle=classic reaches a real tkclient window (%s)", got[0]));
	report(got[1] == "flat", sys->sprint(
		"and anything else leaves it flat, the default (%s)", got[1]));
}




# A colour is a 32-bit value, and three places in libtk built it with
# (r<<24)|... computed as a signed int - so any colour with a red byte of
# 0x80 or more went negative and sign-extended into this platform's
# 64-bit ulong.  #FFFFFFFF was stored as 0xFFFFFFFFFFFFFFFF.
#
# It RENDERED correctly, because tkrgbavals() masks the red byte on the
# way back out, so nothing anyone could see was wrong.  What it broke was
# the value: tkcolor() caches by it and opens with `if(pix == DWhite)
# return d->white', a test a dirty value cannot satisfy, so every -bg
# white missed the display's shared white and allocated a fresh
# one-pixel image under a key that could never match the clean constant.
#
# The signature is visible from here because parse.c formats a colour
# with %.8lux: eight hex digits for a clean value, sixteen for a dirty
# one.  Asking a widget for a colour is therefore a check on the width of
# what is stored, which is why this can be tested at all without any new
# interface.
checkcolourwidth()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	bad := "";
	# one named colour per source: white and red come from xdata.c's
	# table, and a bevel shade is computed by tkrgba()
	tk->cmd(top, "frame .f -width 40 -height 20 -bg white");
	tk->cmd(top, "frame .g -width 40 -height 20 -bg red");
	tk->cmd(top, "frame .h -width 40 -height 20 -borderwidth 2 -relief raised");
	tk->cmd(top, "pack .f");
	tk->cmd(top, "pack .g");
	tk->cmd(top, "pack .h");
	map(top);
	for(l := list of {".f", ".g", ".h"}; l != nil; l = tl l){
		w := hd l;
		c := tk->cmd(top, w + " cget -bg");
		if(len c != 9)		# '#' and eight digits
			bad += sys->sprint(" %s=%s", w, c);
	}
	report(bad == nil, sys->sprint(
		"a colour is stored in 32 bits, not sign-extended to 64%s",
		badly(bad)));
}






# Every widget a person can tab to has to SHOW that it has the keyboard.
#
# The button check below tests one widget, and it exists because that one
# was broken: the two lines that draw its ring were commented out while
# the identical lines ran in label.c.  One widget was tested and one
# widget was wrong, which is not a coincidence - it is what happens when
# a property is checked on an example instead of on the set.
#
# So this asks the same question of every type that sets Tktakefocus:
# button, checkbutton, radiobutton, entry, listbox, text and scale.
checkfocusall()
{
	kinds := array[] of {
		("button",	"button %s -text {Cancel}"),
		("checkbutton",	"checkbutton %s -text {Wrap} -variable fv1"),
		("radiobutton",	"radiobutton %s -text {Third} -variable fv2 -value 1"),
		("entry",	"entry %s -width 120"),
		("listbox",	"listbox %s -width 120 -height 50"),
		("text",	"text %s -width 120 -height 50"),
		("scale",	"scale %s -orient horizontal -from 0 -to 10 -length 120"),
	};
	bad := "";
	for(i := 0; i < len kinds; i++){
		(nm, spec) := kinds[i];
		blank();
		top := offscreen();
		if(top == nil)
			return;
		# two of the same thing, so the only difference between the
		# two readings is which one holds the keyboard
		if(!mk2(top, spec))
			continue;
		map(top);
		# tkhaskeyfocus() is false unless the toplevel itself has the
		# keyboard, which an offscreen window never gets by itself
		tk->cmd(top, "focus -global 1");
		r := tk->rect(top, ".a", Tk->Border);
		tk->cmd(top, "focus .b");
		tk->cmd(top, "update");
		away := grab(r);
		tk->cmd(top, "focus .a");
		tk->cmd(top, "update");
		held := grab(r);
		# ANY difference is not enough.  A text widget answered this
		# check with its blinking CARET - ten pixels, in the middle,
		# gone for half of every second - and the check said OK.  What
		# is wanted is an indication at the widget's EDGE, so only the
		# outer band is counted, and it has to be a substantial part of
		# a perimeter rather than a stray pixel or two.
		n := banddiff(away, held, r, Band);
		want := (r.dx() + r.dy())/2;
		if(n < want)
			bad += sys->sprint(" %s(%d<%d)", nm, n, want);
		else if(verbosefocus)
			sys->print("     %-12s %d of its edge changes with the keyboard (wanted %d)\n",
				nm, n, want);
	}
	report(bad == nil, sys->sprint(
		"every widget that takes the keyboard shows it%s", badly(bad)));
}

verbosefocus := 1;
Band: con 4;		# the outer band a focus ring is expected to land in

mk2(top: ref Tk->Toplevel, spec: string): int
{
	for(l := list of {".a", ".b"}; l != nil; l = tl l){
		w := hd l;
		e := tk->cmd(top, subst2(spec, w));
		if(e != nil && len e > 0 && e[0] == '!'){
			sys->print("     %s: %s\n", w, e);
			return 0;
		}
		tk->cmd(top, "pack " + w + " -padx 6 -pady 6");
	}
	return 1;
}

# Limbo wants a format string to be a compile-time constant, so a widget
# spec cannot go through sprint: put the path in by hand.
subst2(spec, w: string): string
{
	for(i := 0; i < len spec - 1; i++)
		if(spec[i] == '%' && spec[i+1] == 's')
			return spec[0:i] + w + spec[i+2:];
	return spec;
}

# A widget under the pointer has to LOOK different, and how different is
# a number rather than an opinion.
#
# The first flat hover tint was #E2E2DE on a #F0F0ED page: 1.14:1, which
# is no feedback at all.  It went unnoticed because nothing tested hover
# - and it was found sideways, by a control on the MENU highlight
# reporting 1.14:1 and that number turning out to be the hover tint
# rather than anything about menus.
#
# The pointer is delivered rather than simulated: tk->pointer() is the
# same entry the window system uses, so this is the path a hand takes.
checkhover()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, "button .b -text {Cancel}");
	tk->cmd(top, "pack .b -padx 10 -pady 10");
	map(top);
	r := tk->rect(top, ".b", Tk->Border);
	if(r.dx() <= 4 || r.dy() <= 4)
		return;

	# away, then over
	tk->pointer(top, Draw->Pointer(0, Point(r.max.x + 40, r.max.y + 40), 0));
	tk->cmd(top, "update");
	(ar, ag, ab, nil, nil, nil) := twocolours(r);
	tk->pointer(top, Draw->Pointer(0, Point((r.min.x+r.max.x)/2,
		(r.min.y+r.max.y)/2), 0));
	tk->cmd(top, "update");
	(hr, hg, hb, nil, nil, nil) := twocolours(r);

	cr := contrast(ar, ag, ab, hr, hg, hb);
	moved := ar != hr || ag != hg || ab != hb;
	report(moved && cr >= 1.25, sys->sprint(
		"a widget under the pointer looks different (#%.2X%.2X%.2X to #%.2X%.2X%.2X, %d.%.2d:1)",
		ar, ag, ab, hr, hg, hb, whole(cr), frac(cr)));
}

# A posted menu, and the item under the pointer.
#
# Menus are the last thing in this toolkit that looked untouched, and
# they are also the last thing anybody thinks to test, because a popup is
# awkward to get at.  It is not actually awkward: a menu can be posted
# and an item activated by command, which is the same path a pointer
# takes, and then it is pixels like anything else.
checkmenu()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	e := tk->cmd(top, "menu .m");
	if(e != nil && len e > 0 && e[0] == '!'){
		sys->print("     no menu: %s\n", e);
		return;
	}
	for(l := list of {"Open", "Save as", "Close"}; l != nil; l = tl l)
		tk->cmd(top, ".m add command -label " + tk->quote(hd l));
	map(top);
	tk->cmd(top, ".m post 40 40");
	# A posted menu is a separate WINDOW and asks the window system for
	# a backing image, which offscreen there is nobody to answer - so it
	# has a rectangle and draws nothing.  Hand it one the same way the
	# toplevel gets its own, under the id tkclient uses when there is no
	# window manager.  Without this the check reported "0 pixels not the
	# background" and would have read as a menu that draws nothing.
	mw := scr.newwindow(Rect((40,40),(240,200)), Draw->Refbackup, Draw->Nofill);
	if(mw != nil)
		tk->putimage(top, ".m -1", mw, nil);
	tk->cmd(top, ".m activate 1");
	tk->cmd(top, "update");

	r := tk->rect(top, ".m", Tk->Border);
	if(r.dx() <= 0 || r.dy() <= 0){
		sys->print("     menu has no rectangle; not checked\n");
		tk->cmd(top, ".m unpost");
		return;
	}
	# the highlighted row must be the accent, and readable on it
	(br, bg, bb, fr, fg, fb) := twocolours(r);
	cr := contrast(br, bg, bb, fr, fg, fb);
	sys->print("     menu %dx%d, two commonest #%.2X%.2X%.2X and #%.2X%.2X%.2X\n",
		r.dx(), r.dy(), br, bg, bb, fr, fg, fb);
	report(lit(r) > 0, sys->sprint(
		"a posted menu draws something (%d pixels not the background)", lit(r)));
	# The two commonest colours across a whole menu are its BODY and the
	# highlighted row, not text and its background - so this is the
	# separation between the row and the menu, which is what it is named
	# for now.  Text on the accent is the same code path as the
	# checkbutton chip and is measured there, at 5.63:1.
	report(cr >= 3.0 && (br != fr || bg != fg || bb != fb), sys->sprint(
		"and the highlighted row stands out from the menu body (%d.%.2d:1)",
		whole(cr), frac(cr)));
	tk->cmd(top, ".m unpost");
}

# pixels in r that are not the commonest colour
lit(r: Rect): int
{
	return ink(r);
}

whole(x: real): int
{
	w := int x;
	if(real w > x)
		w--;
	return w;
}

frac(x: real): int
{
	return int ((x - real whole(x)) * 100.0);
}

# Text on the accent has to be READABLE, and that is measurable rather
# than a matter of taste.
#
# WCAG asks 4.5:1 for body text, on a ratio computed from linearised
# luminance - not from the raw bytes, which is a different number and the
# one I got wrong first: the raw approximation said 2.38:1 where the real
# figure was 2.80:1, and had the defect been marginal that error would
# have decided it the wrong way.
#
# What was wrong: an indicator-less checkbutton drawn in the accent kept
# the near-black foreground, 2.80:1.  A tknotebook(2) tab is an
# indicator-less radiobutton, so every chosen tab had it too - one defect
# in two places that look nothing alike.
checkcontrast()
{
	if(math == nil){
		sys->print("     no math module; contrast not checked\n");
		return;
	}
	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, "checkbutton .c -text {Wrap lines} -indicatoron 0 -variable cv");
	tk->cmd(top, "pack .c -padx 8 -pady 8");
	map(top);
	tk->cmd(top, ".c select");
	tk->cmd(top, "update");

	r := tk->rect(top, ".c", Tk->Border);
	(br, bg, bb, fr, fg, fb) := twocolours(r);
	cr := contrast(br, bg, bb, fr, fg, fb);
	# int on a real ROUNDS in Limbo, it does not truncate, so `int cr'
	# for 5.63 is 6 and the remainder comes out negative: this printed
	# "6.-37:1".  The comparison above was never affected; only the way
	# it was shown, which is its own kind of wrong - a check that reports
	# a number nobody can read is a check nobody will trust.
	report(cr >= 4.5, sys->sprint(
		"text on the accent meets WCAG AA (#%.2X%.2X%.2X on #%.2X%.2X%.2X is %d.%.2d:1, needs 4.50)",
		fr, fg, fb, br, bg, bb, whole(cr), frac(cr)));
}

# the two commonest colours in a rectangle, commonest first
twocolours(r: Rect): (int, int, int, int, int, int)
{
	if(r.dx() <= 0 || r.dy() <= 0)
		return (0,0,0,0,0,0);
	n := r.dx()*r.dy();
	b := array[n*3] of byte;
	off.readpixels(r, b);
	cnt := array[1<<12] of {* => 0};
	for(i := 0; i < n*3; i += 3){
		k := ((int b[i+2] >> 4) << 8) | ((int b[i+1] >> 4) << 4) | (int b[i] >> 4);
		cnt[k]++;
	}
	b1 := 0;
	b2 := 0;
	for(i = 0; i < len cnt; i++)
		if(cnt[i] > cnt[b1]){
			b2 = b1;
			b1 = i;
		}else if(i != b1 && cnt[i] > cnt[b2])
			b2 = i;
	(r1, g1, l1) := exact(b, n, b1);
	(r2, g2, l2) := exact(b, n, b2);
	return (r1, g1, l1, r2, g2, l2);
}

# a real pixel matching a coarse bucket
exact(b: array of byte, n, bucket: int): (int, int, int)
{
	for(i := 0; i < n*3; i += 3){
		k := ((int b[i+2] >> 4) << 8) | ((int b[i+1] >> 4) << 4) | (int b[i] >> 4);
		if(k == bucket)
			return (int b[i+2], int b[i+1], int b[i]);
	}
	return (0, 0, 0);
}

# WCAG relative luminance.  The channel has to be LINEARISED first, and
# that is the step that makes this different from averaging the bytes: on
# the raw approximation this defect measured 2.38:1 and on the real one
# 2.80:1.  Had it been marginal, the wrong formula would have decided it
# the wrong way.
lumin(r, g, b: int): real
{
	return 0.2126*linear(r) + 0.7152*linear(g) + 0.0722*linear(b);
}

# not chan(): that is a reserved word in Limbo, being the channel type
linear(v: int): real
{
	c := real v / 255.0;
	if(c <= 0.03928)
		return c / 12.92;
	return math->pow((c + 0.055) / 1.055, 2.4);
}

contrast(ar, ag, ab, br, bg, bb: int): real
{
	la := lumin(ar, ag, ab);
	lb := lumin(br, bg, bb);
	if(lb > la)
		(la, lb) = (lb, la);
	return (la + 0.05) / (lb + 0.05);
}

# A label that does not fit has to be cut to a width, not wrapped.
#
# The window manager's toolbar used to wrap a long task title onto four
# lines of fifteen characters, which made a button TALLER and never
# narrower - so the bar's width was whatever the titles added up to, and
# with a flat control half again as wide as a classic one the tasks past
# the end simply fell off.  tklayout(2) does the cutting now, and this is
# the check that it cuts to the width it was given.
checkelide()
{
	if(tklayout == nil)
		return;
	blank();
	top := offscreen();
	if(top == nil)
		return;
	map(top);
	long := "wm/edit /usr/inferno/appl/wm/toolbar.b";
	bad := "";
	# every budget from generous to absurd: the result must never be
	# wider than asked, and must shrink as the budget does
	prev := -1;
	for(w := 240; w >= 20; w -= 20){
		got := tklayout->elide(top, long, w);
		gw := tklayout->measure(top, got);
		if(gw > w)
			bad += sys->sprint(" %d:%dpx", w, gw);
		if(prev >= 0 && gw > prev)
			bad += sys->sprint(" %d:grew", w);
		prev = gw;
	}
	report(bad == nil, sys->sprint(
		"an elided label never exceeds the width it was given%s", badly(bad)));

	# it leaves a string that fits alone, and says it cut when it cut
	short := "sh";
	sw := tklayout->measure(top, short);
	report(tklayout->elide(top, short, sw + 40) == short,
		"and a label that already fits is returned unchanged");
	cut := tklayout->elide(top, long, 120);
	report(len cut < len long && cut[len cut - 3:] == "...",
		sys->sprint("and a cut one ends in an ellipsis (%#q)", cut));
}

# libtk can draw a flat border two ways now: straight to draw(), or by
# building a render-node tree and rendering that.  The node tree is the
# first piece of a GTK4-shaped renderer (see libtk/scene.c), and the only
# thing that makes it worth having yet is this check: the two paths must
# put down the SAME PIXELS.
#
# Byte-for-byte, not "looks the same".  A node tree that is nearly right
# is worse than no node tree, because every later backend gets to be
# correct against it - and a difference of one pixel in a corner is
# exactly what would survive a visual comparison and then be inherited.
checkscene()
{
	if(tk->cmd(top0(), "render") == nil)
		return;			# no render command in this libtk
	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, "style flat");
	# the three that actually have a border to draw
	# A distinct background, and it is load-bearing rather than decorative.
	# With the frame the same colour as the page behind it, the rounded
	# FILL is invisible whatever its radius - a control that perturbed the
	# radius passed, because there was nothing for it to change.  A frame
	# that differs from its parent is the only kind whose corners can be
	# seen at all.
	tk->cmd(top, "frame .f -width 90 -height 46 -borderwidth 2 " +
		"-relief raised -bg white");
	tk->cmd(top, "button .b -text {Cancel}");
	# An entry with TEXT in it, and holding the keyboard.  Empty and
	# unfocused it exercises only the fill and the border, which the
	# frame already covers; the glyph run, the caret and the focus ring
	# are the parts of an entry that have nodes of their own.
	tk->cmd(top, "entry .e -width 150");
	tk->cmd(top, ".e insert 0 {Handgloves}");
	# A label, because a button draws its own text in buton.c and the
	# text NODE is only on label.c's path - without one here the text
	# node is never reached, and a control that perturbs it passes for
	# that reason rather than because it is right.
	tk->cmd(top, "label .t -text {Handgloves 123}");
	tk->cmd(top, "pack .t -padx 6 -pady 6");
	tk->cmd(top, "pack .f -padx 6 -pady 6");
	tk->cmd(top, "pack .b -padx 6 -pady 6");
	# A listbox with items in it, one SELECTED and one ACTIVE.  Empty it
	# draws a fill and a border and nothing else; the item band, the
	# per-item text in two colours and the active item's box are the
	# parts that have nodes of their own.
	tk->cmd(top, "listbox .l -width 150 -height 54");
	tk->cmd(top, ".l insert end {alpha}");
	# WIDER than the widget and MORE than fit, then scrolled in both
	# directions, because every place the two paths could diverge in a
	# listbox is a clipping question: a scrolled item starts at a
	# negative x and the active item's box is as wide as the widest
	# entry, so both run past the edges.  Unscrolled, with three short
	# items, none of that is exercised and the layer's extent is never
	# actually put to the question.
	tk->cmd(top, ".l insert end {beta beta beta beta beta beta beta}");
	tk->cmd(top, ".l insert end {gamma}");
	tk->cmd(top, ".l insert end {delta}");
	tk->cmd(top, ".l insert end {epsilon}");
	tk->cmd(top, ".l insert end {zeta}");
	tk->cmd(top, ".l xview scroll 2 units");
	tk->cmd(top, ".l yview scroll 1 units");
	# 1 and 2 selected with 2 active, so the active item's box is drawn
	# in the SELECT foreground and an unselected item's text in the
	# ordinary one - the two colours that reach the same nodes.
	tk->cmd(top, ".l selection set 1 2");
	tk->cmd(top, ".l activate 2");
	# Both states of a radiobutton, because the ring is drawn either way
	# and the dot only when it is chosen - one of the two is a node the
	# other never reaches.
	tk->cmd(top, "radiobutton .r0 -text {Off} -variable rv -value 0");
	tk->cmd(top, "radiobutton .r1 -text {On} -variable rv -value 1");
	tk->cmd(top, "variable rv 1");
	tk->cmd(top, "pack .e -padx 6 -pady 6");
	tk->cmd(top, "pack .l -padx 6 -pady 6");
	# A scale in both orientations, with every annotation it can draw:
	# a label, the value, and tick marks.  Each of those is a separate
	# node and the widget draws none of them by default.
	must(top, "scale .s -orient horizontal -from 0 -to 100 " +
		"-length 160 -label {Speed} -showvalue 1 -tickinterval 25");
	must(top, ".s set 40");
	must(top, "scale .v -orient vertical -from 0 -to 100 " +
		"-length 90 -label {Gain} -showvalue 1 -tickinterval 50");
	must(top, ".v set 70");
	tk->cmd(top, "pack .r0 -padx 6 -pady 6");
	tk->cmd(top, "pack .r1 -padx 6 -pady 6");
	tk->cmd(top, "pack .s -padx 6 -pady 6");
	tk->cmd(top, "pack .v -padx 6 -pady 6");
	map(top);
	tk->cmd(top, "focus -global 1");
	tk->cmd(top, "focus .e");

	# Prove each path was actually SELECTED before comparing.  Without
	# this the check passed with 0 of 1890000 bytes differing while the
	# render command did not exist at all - both snapshots were the same
	# path, so of course they matched.  A comparison of a thing with
	# itself is the easiest way for a test like this to be worthless.
	tk->cmd(top, "render direct");
	sel1 := tk->cmd(top, "render");
	tk->cmd(top, "render scene");
	sel2 := tk->cmd(top, "render");
	tk->cmd(top, "render direct");
	report(sel1 == "direct" && sel2 == "scene", sys->sprint(
		"both drawing paths can be selected (%#q then %#q)", sel1, sel2));
	if(sel1 != "direct" || sel2 != "scene")
		return;		# comparing identical runs would say nothing

	# One pair PER FOCUSABLE WIDGET, because only one widget can hold the
	# keyboard and each of them has nodes that depend on having it.  With
	# the entry focused the listbox draws neither its ring nor its active
	# item's box - both are guarded by tkhaskeyfocus() - so a
	# perturbation of either passes, which by the usual rule means the
	# check never reached the code rather than that the code is right.
	who := array[] of {".e", ".l", ".s"};
	diff := 0;
	first := -1;
	for(k := 0; k < len who; k++){
		(d, f) := scenepair(top, who[k]);
		if(d < 0){
			report(0, "the offscreen pane reads back");
			return;
		}
		diff += d;
		if(first < 0)
			first = f;
	}
	report(diff == 0, sys->sprint(
		"a render-node tree draws a flat border identically to draw() (%d of %d bytes differ%s)",
		diff, len who*W*H*3, at(first)));
}

# One direct/scene comparison of the whole pane, with `who' holding the
# keyboard.  Returns the bytes that differ and the first of them, or
# (-1, -1) if the pane could not be read.
#
# A caret BLINKS, on a 500ms repeater that runs whether or not there is a
# window manager, so a caret that toggled between the two snapshots would
# report a difference that is the clock's rather than the renderer's.
# Re-focusing resets the phase and turns the caret on, so each snapshot
# is taken a few milliseconds into a fresh half-second of it being lit.
# It goes AWAY and back, because focusing what already has the focus is
# not a focus change and fires no binding.
scenepair(top: ref Tk->Toplevel, who: string): (int, int)
{
	tk->cmd(top, "render direct");
	tk->cmd(top, "focus .b");
	tk->cmd(top, "focus " + who);
	tk->cmd(top, "update");
	a := snap();
	tk->cmd(top, "render scene");
	tk->cmd(top, "focus .b");
	tk->cmd(top, "focus " + who);
	tk->cmd(top, "update");
	b := snap();
	tk->cmd(top, "render direct");
	if(a == nil || b == nil)
		return (-1, -1);
	diff := 0;
	first := -1;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i]){
			diff++;
			if(first < 0)
				first = i;
		}
	if(diff != 0){
		sys->print("     with %s holding the keyboard:\n", who);
		shown := 0;
		for(j := 0; j < len a && shown < 6; j += 3)
			if(a[j] != b[j] || a[j+1] != b[j+1] || a[j+2] != b[j+2]){
				sys->print("     %d,%d direct #%.2X%.2X%.2X scene #%.2X%.2X%.2X\n",
					(j/3)%W, (j/3)/W,
					int a[j+2], int a[j+1], int a[j],
					int b[j+2], int b[j+1], int b[j]);
				shown++;
			}
	}
	return (diff, first);
}

# A command whose failure would otherwise go unnoticed.
#
# Setting a widget up is not what these checks test, so most of this file
# throws the result away.  A scale given an option it does not know is
# never built, and every comparison of it passes; anything that builds the
# subject of a check goes through here, so a failure is at least printed.
must(top: ref Tk->Toplevel, cmd: string): string
{
	e := tk->cmd(top, cmd);
	if(e != nil && len e > 0 && e[0] == '!')
		sys->print("     %s: %s\n", cmd, e);
	return e;
}

# a toplevel to ask cheap questions of, made once
scenetop: ref Tk->Toplevel;

top0(): ref Tk->Toplevel
{
	if(scenetop == nil)
		scenetop = tk->toplevel(disp, "");
	return scenetop;
}

at(i: int): string
{
	if(i < 0)
		return "";
	return sys->sprint(", first at byte %d (pixel %d,%d)", i,
		(i/3)%W, (i/3)/W);
}

# the whole offscreen pane, as bytes
# the outer band, w pixels wide, of two readings of the same rectangle:
# how many pixels differ.  A focus ring lands there; a caret does not.
banddiff(a, b: array of byte, r: Rect, w: int): int
{
	n := 0;
	dx := r.dx();
	for(y := 0; y < r.dy(); y++)
		for(x := 0; x < dx; x++){
			if(x >= w && x < dx - w && y >= w && y < r.dy() - w)
				continue;
			i := (y*dx + x)*3;
			if(a[i] != b[i] || a[i+1] != b[i+1] || a[i+2] != b[i+2])
				n++;
		}
	return n;
}

grab(r: Rect): array of byte
{
	b := array[r.dx()*r.dy()*3] of byte;
	if(off.readpixels(r, b) != len b)
		return array[r.dx()*r.dy()*3] of {* => byte 0};
	return b;
}

snap(): array of byte
{
	b := array[W*H*3] of byte;
	if(off.readpixels(off.r, b) != len b)
		return nil;
	return b;
}

# A raised border is drawn in a LIGHTER and a DARKER shade of the colour
# behind it, and for a long time it was drawn in teal instead - on a
# cream background, #F5F0D8 shading to #00C0AB and #009080.
#
# The cause was two things that were each harmless alone.  colrs.c builds
# its colours with (R<<24)|..., computed as a signed int, so any colour
# with a red byte of 0x80 or more went negative and sign-extended when it
# was widened to this platform's 64-bit ulong.  And tkrgbavals() pulled
# the red byte out with (rgba>>24) and no mask - correct when a ulong is
# 32 bits and the shift alone leaves one byte, wrong here, where the top
# half of the word came too.  Red arrived negative, rgb2hsv() computed a
# hue from it, and the shade came back from a different sector of the
# wheel entirely.  Colours with a red byte under 0x80 were untouched,
# which is why the text and the blue accent always looked right and only
# the BEVELS were wrong.
#
# What makes this checkable without naming a colour: cream has red as its
# largest channel, and every shade of cream must too.  Teal has red as its
# smallest.  So the test is that the border keeps the background's channel
# ORDER, which stays true if anyone ever changes the palette.
checkbevelhue()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	# classic explicitly: this checks the two-tone CHISEL's shades, and
	# the flat style draws one outline and has no second edge to compare.
	tk->cmd(top, "style classic");
	tk->cmd(top, "frame .f -width 90 -height 50 -borderwidth 3 -relief raised");
	tk->cmd(top, "pack .f -padx 10 -pady 10");
	map(top);
	r := tk->rect(top, ".f", Tk->Border);
	if(r.dx() <= 6 || r.dy() <= 6)
		return;
	# the top edge is the light shade, the bottom edge the dark one
	lt := pixel(r.min.x + r.dx()/2, r.min.y);
	dk := pixel(r.min.x + r.dx()/2, r.max.y - 1);
	bg := pixel(r.min.x + r.dx()/2, r.min.y + r.dy()/2);
	sys->print("     background %s, light edge %s, dark edge %s\n",
		hex(bg), hex(lt), hex(dk));
	report(ordered(bg) && ordered(lt) && ordered(dk), sys->sprint(
		"a bevel is a shade of the colour behind it, not another hue (%s / %s / %s)",
		hex(bg), hex(lt), hex(dk)));
	# and it is actually a bevel: two different shades, neither the body
	report(hex(lt) != hex(dk) && hex(lt) != hex(bg), sys->sprint(
		"and its two edges differ from each other and from the body"));
}

# the (r,g,b) of one pixel of the offscreen image
pixel(x, y: int): (int, int, int)
{
	b := array[3] of byte;
	off.readpixels(Rect((x,y),(x+1,y+1)), b);
	# RGB24 is stored little-endian, so byte 0 of a pixel is blue
	return (int b[2], int b[1], int b[0]);
}

hex(c: (int, int, int)): string
{
	(r, g, b) := c;
	return sys->sprint("#%.2X%.2X%.2X", r, g, b);
}

# does this colour keep cream's channel order, red largest and blue
# smallest?  A shade of the background must; a wrong-sector hue will not.
ordered(c: (int, int, int)): int
{
	(r, g, b) := c;
	return r >= g && g >= b;
}

# The widget style: whether a relief is a two-tone chisel or one
# restrained outline.  What makes this measurable rather than a matter of
# taste is that the two looks differ in a way that can be counted - a
# chisel needs a light edge AND a dark edge, so it puts more distinct
# values into the border than a single outline does.
#
# The check that matters most is the last one.  Collapsing raised and
# sunken is only safe because every state that uses a relief also changes
# the fill behind it; an indicator-less checkbutton is the case where the
# relief was doing the work, so if anything was going to lose its state
# to this it is that.  It is checked in BOTH styles, because a flat look
# that quietly stopped saying which option is chosen would be a
# regression no count of grey levels would notice.
checkstyle()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	# A frame carries no text, so every value inside its rectangle comes
	# from the border.  Measured on a button instead, the glyphs dominate
	# the count and the two styles read alike - which is what the first
	# version of this check did, and it reported no difference where
	# there plainly is one.
	tk->cmd(top, "frame .f -width 80 -height 40 -borderwidth 2 -relief raised");
	tk->cmd(top, "pack .f");
	mkcheck(top);
	map(top);

	was := tk->cmd(top, "style");

	# The rectangle has to be fetched AFTER each change, not once at the
	# start: a style sets the spacings too, so the widget is a different
	# size and in a different place afterwards.  Measured through the old
	# rectangle both styles read 3 values - not because they look alike
	# but because the reading was of the wrong pixels.
	tk->cmd(top, "style classic");
	tk->cmd(top, "update");
	classic := levels(tk->rect(top, ".f", Tk->Border));
	tk->cmd(top, "style flat");
	tk->cmd(top, "update");
	flat := levels(tk->rect(top, ".f", Tk->Border));

	report(was == "flat",
		sys->sprint("the default style is flat (%s)", was));
	report(tk->cmd(top, "style") == "flat",
		"the style command reports back what was set");
	report(flat < classic, sys->sprint(
		"a flat border uses fewer distinct values than a chisel (%d against %d)",
		flat, classic));
	report(flat > 1, sys->sprint(
		"a flat widget still has a border at all (%d values)", flat));

	# The state a relief used to carry.  Collapsing raised and sunken is
	# only safe because every state that used one also changes the fill;
	# an indicator-less checkbutton is where the relief was doing the
	# work, so it is checked in BOTH styles - a flat look that quietly
	# stopped saying which option is chosen would be a regression no
	# count of grey levels would notice.
	bad := "";
	for(sl := list of {"classic", "flat"}; sl != nil; sl = tl sl){
		st := hd sl;
		tk->cmd(top, "style " + st);
		tk->cmd(top, ".c deselect");
		tk->cmd(top, "update");
		off0 := dominant(tk->rect(top, ".c", Tk->Border));
		tk->cmd(top, ".c select");
		tk->cmd(top, "update");
		on := dominant(tk->rect(top, ".c", Tk->Border));
		# Not ink(): that counts pixels which are not the commonest
		# value, and a fill which merely CHANGES COLOUR leaves that
		# count exactly where it was.  It read 366 either way in both
		# styles - a number with no power to answer the question.
		sys->print("     %-8s checked %s, unchecked %s\n", st, on, off0);
		if(on == off0)
			bad += " " + st;
	}
	report(bad == nil, sys->sprint(
		"an indicator-less checkbutton still shows its state%s",
		badly(bad)));

	# The spacings moved out of four scattered per-file constants into
	# one register, and the flat row is roomier.  Without this the
	# register's interesting row would never be read by any test: the
	# classic row is exercised by every other check in this file, which
	# is precisely why it proves nothing about the table working.
	#
	# A spacing is read when a widget is CONFIGURED, so the widget is
	# destroyed and built again rather than merely restyled - which is
	# how a program uses this and what style(9) says to do.  Restyling
	# in place and expecting the size to follow was tried: the new size
	# request travels up to the toplevel, which re-fits itself to its
	# contents, and one command resized the window and moved every
	# widget in it.
	tk->cmd(top, "style classic");
	tk->cmd(top, "destroy .c");
	mkcheck(top);
	tk->cmd(top, "update");
	(cw, ch) := size(top, ".c");
	tk->cmd(top, "style flat");
	tk->cmd(top, "destroy .c");
	mkcheck(top);
	tk->cmd(top, "update");
	(fw, fh) := size(top, ".c");
	sys->print("     checkbutton classic %dx%d, flat %dx%d\n", cw, ch, fw, fh);
	report(fw > cw && fh > ch, sys->sprint(
		"the flat style insets a widget's contents further (%dx%d against %dx%d)",
		fw, fh, cw, ch));

	checkscaledborder();
}

# A one-pixel line reads as an edge at the tree's own font and as a
# hairline beside one twice as tall.  Under the flat style the default
# border is derived from the font instead, the way the titlebar's artwork
# already is.
#
# It has to be the TOPLEVEL's font, not the widget's: the default border
# is set when the object is made, before tkparse() has looked at the
# widget's own -font, so a `-font' on the button itself arrives too late
# to be measured.  Hence two toplevels rather than two buttons.
checkscaledborder()
{
	sm := "/fonts/lucidasans/unicode.8.font";	# 15 pixels high
	lg := "/fonts/pelm/ascii.16.font";		# 30
	bs := array[2] of int;
	bc := array[2] of int;
	fonts := array[2] of {sm, lg};
	for(i := 0; i < 2; i++){
		blank();
		t := tk->toplevel(disp, "-font " + fonts[i]);
		if(t == nil)
			return;
		t.screenr = off.r;
		tk->cmd(t, "style flat");
		tk->cmd(t, "button .b -text {Cancel}");
		tk->cmd(t, "pack .b");
		bs[i] = int tk->cmd(t, ".b cget -borderwidth");

		t2 := tk->toplevel(disp, "-font " + fonts[i]);
		if(t2 == nil)
			return;
		t2.screenr = off.r;
		# explicitly classic: it is the control for "a classic border
		# does not scale", and since flat became the default a toplevel
		# that says nothing is no longer classic.
		tk->cmd(t2, "style classic");
		tk->cmd(t2, "button .b -text {Cancel}");
		tk->cmd(t2, "pack .b");
		bc[i] = int tk->cmd(t2, ".b cget -borderwidth");
	}
	sys->print("     border flat %d -> %d, classic %d -> %d (font 15 -> 30)\n",
		bs[0], bs[1], bc[0], bc[1]);
	report(bs[1] > bs[0], sys->sprint(
		"a flat border grows with the font (%d at 15 pixels, %d at 30)",
		bs[0], bs[1]));
	report(bc[0] == bc[1] && bc[0] == 1, sys->sprint(
		"and a classic border does not, as every existing layout assumes (%d and %d)",
		bc[0], bc[1]));
}

# the one widget whose relief WAS its state, built the same way every time
mkcheck(top: ref Tk->Toplevel)
{
	tk->cmd(top, "checkbutton .c -text {Wrap} -indicatoron 0 " +
		"-borderwidth 2 -variable cbv");
	tk->cmd(top, "pack .c");
}

# a widget's own width and height, as the toolkit sized it
size(top: ref Tk->Toplevel, w: string): (int, int)
{
	r := tk->rect(top, w, Tk->Border);
	return (r.dx(), r.dy());
}

badly(bad: string): string
{
	if(bad == nil)
		return "";
	return " - NOT in" + bad;
}

# how many distinct values a rectangle holds
levels(r: Rect): int
{
	if(r.dx() <= 0 || r.dy() <= 0)
		return 0;
	n := r.dx()*r.dy();
	b := array[n*3] of byte;
	off.readpixels(r, b);
	seen := array[256] of {* => 0};
	for(i := 0; i < n*3; i += 3)
		seen[int b[i]] = 1;
	d := 0;
	for(i = 0; i < 256; i++)
		if(seen[i])
			d++;
	return d;
}

# how many pixels in a rectangle are not the background
ink(r: Rect): int
{
	if(r.dx() <= 0 || r.dy() <= 0)
		return 0;
	n := r.dx()*r.dy();
	b := array[n*3] of byte;
	off.readpixels(r, b);
	seen := array[256] of {* => 0};
	for(i := 0; i < n*3; i += 3)
		seen[int b[i]]++;
	most := 0;
	for(i = 0; i < 256; i++)
		if(seen[i] > most)
			most = seen[i];
	return n - most;
}

# "dtag X Y" takes tag Y off the items tagged X, and X and Y may be the
# same tag - which is the natural way to take a tag off everything that
# has it, and what appl/wm/ftree/items.b does.  That made the deletion
# walk the list it was freeing from, and wm/ftree died on startup taking
# emu with it.  A canvas is not something this test otherwise touches;
# this is here because the crash was.
#
# How it behaves with the bug back is worth knowing before relying on it:
# not cleanly.  The corrupted list becomes circular and libtk spins inside
# a single tk->cmd(), so this hangs rather than reporting - no Limbo
# timeout can interrupt C.  A suite runner notices; a reader of the output
# does not.  Worth having anyway, since the bug it guards took emu down
# entirely, but it is not a check that says what went wrong.
checkcanvastag()
{
	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, "canvas .c -width 200 -height 100");
	tk->cmd(top, "pack .c");
	for(i := 0; i < 4; i++){
		e := tk->cmd(top, sys->sprint(
			".c create rectangle %d 10 %d 40 -tags mark", i*20, i*20+10));
		if(len e > 0 && e[0] == '!'){
			sys->print("     no canvas rectangles (%s); tags not checked\n", e);
			return;
		}
	}
	map(top);
	before := tk->cmd(top, ".c find withtag mark");

	# the aliasing case: both names the same tag
	tk->cmd(top, ".c dtag mark mark");
	after := tk->cmd(top, ".c find withtag mark");

	report(before != "" && after == "", sys->sprint(
		"a tag can be deleted from the items that have it (%#q then %#q)",
		before, after));

	# and the canvas is still usable, which is the half the crash took
	still := tk->cmd(top, ".c create rectangle 0 50 10 60 -tags later");
	report(len still > 0 && still[0] != '!', sys->sprint(
		"and the canvas still works afterwards (%#q)", still));
}

# A window without a titlebar has no .Wm_t.title, and asking a widget
# that is not there for its text is an error that tkclient(2) reports on
# standard error - which is what wm/logon printed on every focus until
# the call that did it was removed.  titlebar(2)'s own accessor checks
# first, and tkclient uses it now, so this pins that contract.
checkplaintitle()
{
	if(titlebar == nil){
		sys->print("     no titlebar module; not checked\n");
		return;
	}
	blank();
	bare := offscreen();
	if(bare == nil)
		return;
	# no titlebar->new at all: the shape of a Plain window
	got := titlebar->title(bare);
	report(got == nil, sys->sprint(
		"asking a window with no titlebar for its title gives nothing (%#q)",
		got));

	# and the raw query, which is what the removed code did, is an error
	raw := tk->cmd(bare, ".Wm_t.title cget -text");
	report(len raw > 0 && raw[0] == '!', sys->sprint(
		"where asking the widget directly is an error (%#q)", raw));
}

# The window system's colours moved out of titlebar.b into wmtheme(2).
# A refactor of a look must change no pixel, so this checks both ends:
# that the register still holds what was written down before, and that
# what reaches the page is what the register says.
checktheme()
{
	if(wmtheme == nil || titlebar == nil){
		sys->print("     no wmtheme module; colours not checked\n");
		return;
	}
	# The values that were literals in titlebar.b and wmclient.b.
	was := array[] of {
		(Wmtheme->Inactive, "#8A9098"),
		(Wmtheme->Focused, "#3D6A9A"),
		(Wmtheme->Chrome, "#D4D0C4"),
		(Wmtheme->Glyph, "#2A2A22"),
		(Wmtheme->Desktop, "#C4C0B4"),
	};
	bad := "";
	for(i := 0; i < len was; i++){
		(w, want) := was[i];
		got := wmtheme->hex(w);
		if(got != want)
			bad += sys->sprint(" %s=%s(was %s)", wmtheme->name(w), got, want);
	}
	report(bad == "", sys->sprint(
		"the theme register holds the colours that were literals%s", bad));

	# and the titlebar on the page is actually that colour
	blank();
	top := offscreen();
	if(top == nil)
		return;
	titlebar->new(top, Titlebar->Appl);
	titlebar->settitle(top, "Colour");
	map(top);
	bar := tk->rect(top, ".Wm_t", Tk->Border);
	seen := dominant(bar);
	report(seen == wmtheme->hex(Wmtheme->Inactive), sys->sprint(
		"and the titlebar is drawn in it (%s, register says %s)",
		seen, wmtheme->hex(Wmtheme->Inactive)));
}

# the most common colour in a rectangle, as "#RRGGBB"
dominant(r: Rect): string
{
	if(r.dx() <= 0 || r.dy() <= 0)
		return "";
	n := r.dx()*r.dy();
	b := array[n*3] of byte;
	off.readpixels(r, b);
	# RGB24 is stored little-endian, so byte 0 of a pixel is blue.
	cnt := array[1<<12] of {* => 0};	# 4 bits a channel is plenty here
	for(i := 0; i < n*3; i += 3){
		k := ((int b[i+2] >> 4) << 8) | ((int b[i+1] >> 4) << 4) | (int b[i] >> 4);
		cnt[k]++;
	}
	best := 0;
	bk := 0;
	for(i = 0; i < len cnt; i++)
		if(cnt[i] > best){
			best = cnt[i];
			bk = i;
		}
	# find an exact pixel matching that coarse bucket, and report it
	for(i = 0; i < n*3; i += 3){
		k := ((int b[i+2] >> 4) << 8) | ((int b[i+1] >> 4) << 4) | (int b[i] >> 4);
		if(k == bk)
			return sys->sprint("#%.2X%.2X%.2X",
				int b[i+2], int b[i+1], int b[i]);
	}
	return "";
}

#
# What libtk tells voice(3) when the keyboard moves and when a control
# changes.  voicetest(1) checks that the announce levels are accepted and
# that an announcement written by hand comes back out, and says of the
# rest: "checked under wm by hand, not here: it needs a window system and
# a focus to move."  This has one.
#
checkvoice()
{
	if(sys->bind("#V", "/dev", Sys->MAFTER) < 0){
		sys->print("     no voice device; announcements not checked\n");
		return;
	}
	cfd := sys->open("/dev/voice/ctl", Sys->OWRITE);
	sfd := sys->open("/dev/voice/screen", Sys->OREAD);
	if(cfd == nil || sfd == nil){
		sys->print("     no /dev/voice; announcements not checked\n");
		return;
	}
	if(sys->fprint(cfd, "announce focus") < 0){
		sys->print("     cannot set the announce level; not checked\n");
		return;
	}

	blank();
	top := offscreen();
	if(top == nil)
		return;
	tk->cmd(top, "checkbutton .c -text {Wrap lines} -variable w");
	tk->cmd(top, "pack .c");
	map(top);
	drain(sfd);

	tk->cmd(top, "focus .c");
	tk->cmd(top, "update");
	said := next(sfd);
	report(has(said, "Wrap lines") && has(said, "not checked"), sys->sprint(
		"focusing a control says what it is and how it is set (%#q)", said));

	tk->cmd(top, ".c invoke");
	tk->cmd(top, "update");
	said = next(sfd);
	# The label is deliberately not repeated: the person just acted on a
	# control they were told about when they arrived at it.
	report(said == "checked", sys->sprint(
		"and changing it says what it became (%#q)", said));

	# A choicebutton is this toolkit's combobox, and it is the widget the
	# plan for all this listed as MISSING - it is not, it just is not
	# called one.  What was genuinely missing is this: it has no label of
	# its own, what it displays IS the chosen value, so arriving at it
	# always said the right thing and CHANGING it said nothing at all.
	blank();
	tc := offscreen();
	if(tc == nil)
		return;
	tk->cmd(tc, "choicebutton .cb -values {Red Green Blue} -variable cbi");
	tk->cmd(tc, "pack .cb");
	map(tc);
	drain(sfd);
	tk->cmd(tc, "focus .cb");
	tk->cmd(tc, "update");
	said = next(sfd);
	report(has(said, "Red") && has(said, "choice button"), sys->sprint(
		"arriving at a combobox says the value it is showing (%#q)", said));

	tk->cmd(tc, ".cb set 2");
	tk->cmd(tc, "update");
	said = next(sfd);
	report(said == "Blue", sys->sprint(
		"and choosing another one says which (%#q)", said));

	# A slider is the case with no label at all, so its value is the only
	# thing there is to say.  Arrow keys move it, so a person using their
	# ears can, and needs to hear what happened.
	blank();
	t2 := offscreen();
	if(t2 == nil)
		return;
	tk->cmd(t2, "scale .s -orient horizontal -from 0 -to 100");
	tk->cmd(t2, ".s set 40");
	tk->cmd(t2, "pack .s");
	map(t2);
	drain(sfd);
	tk->cmd(t2, "focus .s");
	tk->cmd(t2, "update");
	said = next(sfd);
	report(has(said, "scale") && has(said, "40"), sys->sprint(
		"focusing a slider says where it is set (%#q)", said));

	tk->cmd(t2, sys->sprint(".s tkScaleKey 0x%x", 16rE015));	# Keyboard->Right
	tk->cmd(t2, "update");
	said = next(sfd);
	report(said != "" && said != "40", sys->sprint(
		"and moving it with a key says the new value (%#q)", said));

	# A list's whole content is which line you are on, so a list that
	# says only "list" is one a person using their ears cannot read.
	blank();
	t3 := offscreen();
	if(t3 == nil)
		return;
	tk->cmd(t3, "listbox .l");
	tk->cmd(t3, ".l insert end {Inbox} {Drafts} {Sent}");
	tk->cmd(t3, ".l activate 0");
	tk->cmd(t3, "pack .l");
	map(t3);
	drain(sfd);
	tk->cmd(t3, "focus .l");
	tk->cmd(t3, "update");
	said = next(sfd);
	report(has(said, "Inbox"), sys->sprint(
		"focusing a list says which line the cursor is on (%#q)", said));

	tk->cmd(t3, sys->sprint(".l tkListbKey 0x%x", 16rE013));	# Keyboard->Down
	tk->cmd(t3, "update");
	said = next(sfd);
	report(has(said, "Drafts"), sys->sprint(
		"and walking it with a key says the new line (%#q)", said));

	# An ordinary field is read; a masked one is not.  The order matters:
	# voice(3) drops an announcement identical to the last one queued, so
	# the masked field is only heard at all because the field before it
	# said something different.  With the reading broken both would say
	# "entry" and the second would vanish - which is what the control
	# shows, and is a true report rather than a flaw in the test.
	#
	# Both halves matter:
	# a field that says only "entry" cannot be read by ear at all, and a
	# password read aloud is the failure that policy exists to prevent.
	blank();
	t4 := offscreen();
	if(t4 == nil)
		return;
	tk->cmd(t4, "entry .n");
	tk->cmd(t4, ".n insert 0 {notes.txt}");
	tk->cmd(t4, "entry .p -show *");
	tk->cmd(t4, ".p insert 0 {hunter2}");
	tk->cmd(t4, "pack .n");
	tk->cmd(t4, "pack .p");
	map(t4);
	drain(sfd);
	tk->cmd(t4, "focus .n");
	tk->cmd(t4, "update");
	said = next(sfd);
	report(has(said, "notes.txt"), sys->sprint(
		"focusing a field says what is in it (%#q)", said));

	tk->cmd(t4, "focus .p");
	tk->cmd(t4, "update");
	said = next(sfd);
	# said == "entry", not merely "hunter2 is absent": an announcement
	# that failed altogether would also lack the secret, and would pass a
	# check written the loose way while telling us nothing.
	report(said == "entry", sys->sprint(
		"but a masked field is not read aloud (%#q)", said));

	# Everything above was consumed by reading it.  The point of the
	# history file is that a person who missed something can ask again,
	# so it must still hold all of it, newest first, and still hold it
	# after being read once.
	# Distinguish "the file is not there" from "the file is empty".  In
	# Limbo an empty string is nil, so testing the contents alone would
	# turn a broken history into a skipped check, which is how a test
	# goes quietly blind.  Ask whether it opens; if it does, its contents
	# are the test.
	hfd := sys->open("/dev/voice/history", Sys->OREAD);
	if(hfd == nil){
		sys->print("     no /dev/voice/history; review not checked\n");
		return;
	}
	hfd = nil;
	h1 := slurpfile("/dev/voice/history");
	want := array[] of {"entry", "entry notes.txt", "Drafts", "list Inbox",
		"50", "scale 40", "checked", "Wrap lines check button not checked"};
	inorder := 1;
	at := 0;
	for(i := 0; i < len want; i++){
		j := find(h1, want[i], at);
		if(j < 0){
			inorder = 0;
			break;
		}
		at = j + 1;
	}
	report(inorder, sys->sprint(
		"the history holds everything that was said, newest first (%d lines)",
		lines(h1)));

	h2 := slurpfile("/dev/voice/history");
	report(h2 == h1, "and reading it does not consume it");

	# tknotebook(2) makes its tabs radiobuttons rather than buttons, on
	# the grounds that a control with a state announces itself and a
	# button does not.  That is a claim about this system's behaviour, so
	# it is checked rather than asserted in a comment.
	if(tknotebook == nil)
		return;
	blank();
	t5 := offscreen();
	if(t5 == nil)
		return;
	nb := tknotebook->new(t5, ".nb", array[] of {"General", "Fonts"});
	if(nb == nil)
		return;
	tk->cmd(t5, "pack .nb");
	map(t5);
	drain(sfd);
	tk->cmd(t5, "focus .nb.tabs.t0");
	tk->cmd(t5, "update");
	said = next(sfd);
	report(has(said, "General") && has(said, "selected"), sys->sprint(
		"a notebook tab says its name and that it is chosen (%#q)", said));

	# Arriving in a window used to say "window", or where the keyboard
	# was inside it, because Tk has no title of its own. It can be told
	# one now: titlebar(2) puts it in the variable libtk reads.
	if(titlebar == nil)
		return;
	blank();
	t6 := offscreen();
	if(t6 == nil)
		return;
	titlebar->new(t6, Titlebar->Appl);
	titlebar->settitle(t6, "Mail Reader");
	tk->cmd(t6, "label .l -text {body}");
	tk->cmd(t6, "pack .l");
	map(t6);
	tk->cmd(t6, "focus -global 0");
	tk->cmd(t6, "update");
	drain(sfd);
	tk->cmd(t6, "focus -global 1");
	tk->cmd(t6, "update");
	said = next(sfd);
	# "... window" and not just the name: this is the wording wmclient.b
	# used when it said this itself, and it tells a person that a window
	# changed rather than merely naming something.
	report(said == "Mail Reader window", sys->sprint(
		"entering a window says which window (%#q)", said));

	# Moving about in text is most of what a person does in a shell
	# window, and it said nothing: output was announced and could not be
	# read back.  A line when the cursor changes line, a character when
	# it does not - up and down to survey, left and right to spell out.
	blank();
	t7 := offscreen();
	if(t7 == nil)
		return;
	tk->cmd(t7, "text .t -width 40 -height 5");
	tk->cmd(t7, ".t insert end 'first line\n");
	tk->cmd(t7, ".t insert end 'second line");
	tk->cmd(t7, "pack .t");
	map(t7);
	tk->cmd(t7, ".t mark set insert 1.0");
	tk->cmd(t7, "update");
	drain(sfd);

	tk->cmd(t7, ".t tkTextSetCursor {insert+1l}");
	tk->cmd(t7, "update");
	said = next(sfd);
	report(has(said, "second"), sys->sprint(
		"moving to another line reads the line (%#q)", said));

	tk->cmd(t7, ".t mark set insert 2.0");
	tk->cmd(t7, "update");
	drain(sfd);
	tk->cmd(t7, ".t tkTextSetCursor {insert+1c}");
	tk->cmd(t7, "update");
	said = next(sfd);
	report(said == "e", sys->sprint(
		"and moving along one reads the character (%#q)", said));

	# A menu highlights an item without the keyboard focus moving, so
	# nothing else in libtk says which item a person is on: walking a
	# menu was silent from the moment it opened.
	blank();
	t8 := offscreen();
	if(t8 == nil)
		return;
	tk->cmd(t8, "menu .m");
	tk->cmd(t8, ".m add command -label {Open}");
	tk->cmd(t8, ".m add command -label {Save as}");
	tk->cmd(t8, "menubutton .mb -text {File} -menu .m");
	tk->cmd(t8, "pack .mb");
	map(t8);
	drain(sfd);
	e := tk->cmd(t8, ".m activate 1");
	if(len e > 0 && e[0] == '!'){
		sys->print("     cannot activate a menu item (%s); not checked\n", e);
		return;
	}
	tk->cmd(t8, "update");
	said = next(sfd);
	# "menu item" and not "label": a command item is made as a label, so
	# its type is true and useless - what a person needs to hear is that
	# they are in a menu.
	report(has(said, "Save as") && has(said, "menu item"), sys->sprint(
		"moving through a menu says which item (%#q)", said));
}

slurpfile(p: string): string
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[4096] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n <= 0)
			break;
		s += string b[0:n];
	}
	return s;
}

# index of sub in s at or after from, or -1
find(s, sub: string, from: int): int
{
	for(i := from; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

lines(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			n++;
	return n;
}

waiting(): int
{
	fd := sys->open("/dev/voice/ctl", Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 0;
	for(l := sys->tokenize(string b[0:n], "\n").t1; l != nil; l = tl l){
		f := sys->tokenize(hd l, " ").t1;
		if(f != nil && hd f == "waiting" && tl f != nil)
			return int hd tl f;
	}
	return 0;
}

drain(fd: ref Sys->FD)
{
	b := array[512] of byte;
	for(i := 0; i < 64 && waiting() > 0; i++)
		sys->read(fd, b, len b);
}

next(fd: ref Sys->FD): string
{
	if(waiting() <= 0)
		return "";
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	s := string b[0:n];
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

# what fraction of a rectangle is not the background it sits on
inkfraction(r: Rect): real
{
	if(r.dx() <= 0 || r.dy() <= 0)
		return 0.0;
	n := r.dx()*r.dy();
	b := array[n*3] of byte;
	off.readpixels(r, b);
	seen := array[256] of {* => 0};
	for(i := 0; i < n*3; i += 3)
		seen[int b[i]]++;
	most := 0;
	for(i = 0; i < 256; i++)
		if(seen[i] > most)
			most = seen[i];
	return real (n - most) / real n;
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
