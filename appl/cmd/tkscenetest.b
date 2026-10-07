implement Tkscenetest;

#
# Does libtk's render-node path draw what the direct path draws, in this
# kernel?
#
# The node path (`render scene') describes a widget as a tree of nodes and
# then renders the tree; the direct path (`render direct', the default,
# since tkviascene is zero-initialised) paints straight into the image.
# They are meant to produce the SAME PIXELS -- that is the whole acceptance
# condition for the tree, because a description that draws something else
# is not a description of the drawing.
#
# Everything here reads back from an allocated image rather than looking at
# the screen, for the reason tkofftest(1) gives: what a widget put on the
# screen cannot be read back, while an allocated image can.  That also
# makes this runnable in a kernel with no display attached.
#
# WHY `render count' IS CHECKED AND NOT JUST THE PIXELS: identity between
# the two paths is exactly what you get if `render scene' silently did
# nothing and both runs took the direct path.  A pixel comparison cannot
# tell "the node path agrees" from "the node path never ran".  So the
# count of trees, widgets and nodes is read back too, and a zero there is
# a FAILURE even when every image matches.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Screen: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;

Tkscenetest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ok, fail, skipped: int;
verbose: int;

#
# A case that cannot be built HERE, for a reason that is about the
# environment rather than about libtk -- the only one so far is a
# non-default font, and the Pi 3B kernel's root carries exactly one font
# (/fonts/pelm/unicode.8.font, which is also Tk's default) so there is no
# second face to ask for there.  Reported as skipped and counted
# separately, because a case silently dropped is coverage silently lost,
# and a case failed for a missing font is a false alarm about the node
# path.
#
skip(what: string)
{
	skipped++;
	sys->print("SKIP %s\n", what);
}

report(good: int, what: string)
{
	if(good){
		ok++;
		if(verbose)
			sys->print("OK   %s\n", what);
	}else{
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

W: con 160;
H: con 60;

# scene.c:675's Maxwalk, and the depth used to exceed it.  Named here
# because the nest check's whole point is the boundary between them.
Maxwalk: con 8;
Mid: con 5;
Deep: con 10;

# Lay out one widget specification into a fresh image and hand back its
# pixels.  A toplevel of its own each time, because reconfiguring one and
# reading it again measures whatever the reconfigure happened to repaint,
# which is not the question.  (The idiom is raspi3binit.b's.)
paint(disp: ref Display, name: string, cmds: list of string): array of byte
{
	off := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
	if(off == nil){
		sys->print("FAIL newimage: %r\n");
		return nil;
	}
	top := tk->toplevel(disp, "");
	if(top == nil){
		sys->print("FAIL toplevel: %r\n");
		return nil;
	}
	#
	# Every command's reply is checked, not just the creation's.  A
	# setup step that fails silently -- a selection that did not take,
	# an item that was not added -- leaves a DEFAULT widget being
	# compared against itself, which passes and covers nothing.  That
	# is tkofftest(1)'s creation-error lesson applied to the steps
	# after creation.
	#
	for(l := cmds; l != nil; l = tl l){
		c := tk->cmd(top, hd l);
		if(c != nil && len c > 0 && c[0] == '!'){
			sys->print("FAIL %s: `%s\' -> %s\n", name, hd l, c);
			return nil;
		}
	}
	pc := tk->putimage(top, ". -1", off, nil);
	if(pc != nil && len pc > 0){
		sys->print("FAIL putimage: %s\n", pc);
		return nil;
	}
	tk->cmd(top, "update");
	b := array[W*H*3] of byte;
	if(off.readpixels(off.r, b) != len b){
		sys->print("FAIL readpixels: %r\n");
		return nil;
	}
	return b;
}

#
# A posted menu, which needs a Screen and so cannot go through paint().
#
# A posted menu is a separate WINDOW and asks the window system for a backing
# image; offscreen there is nobody to answer, so it gets a rectangle and draws
# nothing unless it is handed one -- the trap tkofftest(1)'s checkmenu()
# records, where the check read "0 pixels" and would have passed as a menu
# that draws nothing.  The window is made over the same Screen as the
# toplevel, so what the menu draws lands in the image this reads back.
#
# Two items earn their place rather than padding the menu:
#
#   a SEPARATOR paints into the window itself, which makes the walk FLUSH in
#   the middle of the menu -- the case that says drawmenu must not hold the
#   walk's tree in a variable across it, because the flush frees it;
#
#   and `activate' is required, because the slab behind an item is the
#   background colour unless the pointer is on it, so without it the menu's
#   own fill node is the same colour as what is already there and a
#   perturbation of it changes no pixel.
#
# The cascade is the point: its arrow is the one thing tkdrawlabel() drew with
# fillpoly() rather than through a node, and it is only ever seen posted.
#
paintmenu(disp: ref Display, post: int): array of byte
{
	off := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
	if(off == nil){
		sys->print("FAIL menu: newimage: %r\n");
		return nil;
	}
	scr := Screen.allocate(off, disp.color(Draw->White), 0);
	if(scr == nil){
		sys->print("FAIL menu: Screen.allocate: %r\n");
		return nil;
	}
	win := scr.newwindow(off.r, Draw->Refbackup, Draw->Nofill);
	top := tk->toplevel(disp, "");
	if(win == nil || top == nil){
		sys->print("FAIL menu: no window or toplevel: %r\n");
		return nil;
	}
	for(l := list of {"menu .mn", ".mn add command -label {Open}",
	    ".mn add separator", ".mn add cascade -label {Recent}",
	    ".mn add command -label {Close}"}; l != nil; l = tl l){
		c := tk->cmd(top, hd l);
		if(c != nil && len c > 0 && c[0] == '!'){
			sys->print("FAIL menu: `%s\' -> %s\n", hd l, c);
			return nil;
		}
	}
	if((e := tk->putimage(top, ". -1", win, nil)) != nil && len e > 0){
		sys->print("FAIL menu: putimage toplevel: %s\n", e);
		return nil;
	}
	#
	# With post == 0 the menu is BUILT and never posted, which is the
	# control: `28800 bytes of ink' for the posted version proves only
	# that the toplevel painted its own grey background, since inked()
	# counts bytes differing from white.  The two must differ, or this
	# case is comparing two empty toplevels and says nothing about a
	# menu -- the same failure tkofftest(1) hit when the menu had no
	# backing image and the check read "0 pixels not the background".
	#
	if(post){
		mw := scr.newwindow(Rect((4,2),(W-4,H-2)), Draw->Refbackup, Draw->Nofill);
		if(mw == nil){
			sys->print("FAIL menu: no window for the menu itself: %r\n");
			return nil;
		}
		tk->cmd(top, ".mn post 4 2");
		if((e = tk->putimage(top, ".mn -1", mw, nil)) != nil && len e > 0){
			sys->print("FAIL menu: putimage menu: %s\n", e);
			return nil;
		}
		tk->cmd(top, ".mn activate 1");
	}
	tk->cmd(top, "update");
	b := array[W*H*3] of byte;
	if(off.readpixels(off.r, b) != len b){
		sys->print("FAIL menu: readpixels: %r\n");
		return nil;
	}
	if(post)
		tk->cmd(top, ".mn unpost");
	return b;
}

#
# A nest deep enough to overflow the walk, which is the one fallback in
# scene.c that nothing reaches by accident.
#
# tkwalkopen() (scene.c:716) is called from exactly one place, windw.c:348,
# so a walk level is pushed per WINDOW drawn -- and a canvas window item is
# a window.  Maxwalk is 8, commented "a canvas in a text in a canvas ...",
# and past it tkwalkopen returns without pushing: "deeper than this: no
# batching, still correct".  tkofftest(1) nests canvas -> frame -> entry,
# which is two or three levels, so the fallback has never run.  A fallback
# that does not run on demand has to be made to run.
#
# `still correct' is the claim under test: with batching lost the pixels
# must be the same anyway.  So this renders the nest both ways like any
# other case, and the depth is what makes it interesting rather than the
# widget.
#
paintnest(disp: ref Display, depth: int): array of byte
{
	off := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
	top := tk->toplevel(disp, "");
	if(off == nil || top == nil){
		sys->print("FAIL nest: no image or toplevel: %r\n");
		return nil;
	}
	# canvas .c, then frame .c.f in a window item, then canvas .c.f.c in
	# that, and so on.  Each canvas contributes a window, so each level
	# is a walk level.
	path := ".c";
	cmds: list of string;
	cmds = "canvas .c -width 140 -height 44" :: cmds;
	for(i := 0; i < depth; i++){
		f := path + ".f";
		cmds = ("frame " + f + " -width 120 -height 36 -borderwidth 1 -relief sunken") :: cmds;
		cmds = (path + " create window 2 2 -window " + f + " -anchor nw") :: cmds;
		c := f + ".c";
		cmds = ("canvas " + c + " -width 110 -height 30") :: cmds;
		cmds = ("pack " + c) :: cmds;
		path = c;
	}
	# something that marks pixels at the bottom, so the deepest level is
	# not an empty box
	cmds = (path + " create rectangle 2 2 40 16 -fill red") :: cmds;
	cmds = "pack .c" :: cmds;
	# the list was built backwards
	ord: list of string;
	for(l := cmds; l != nil; l = tl l)
		ord = hd l :: ord;
	for(l = ord; l != nil; l = tl l){
		c := tk->cmd(top, hd l);
		if(c != nil && len c > 0 && c[0] == '!'){
			sys->print("FAIL nest depth %d: `%s\' -> %s\n", depth, hd l, c);
			return nil;
		}
	}
	e := tk->putimage(top, ". -1", off, nil);
	if(e != nil && len e > 0){
		sys->print("FAIL nest: putimage: %s\n", e);
		return nil;
	}
	tk->cmd(top, "update");
	b := array[W*H*3] of byte;
	if(off.readpixels(off.r, b) != len b){
		sys->print("FAIL nest: readpixels: %r\n");
		return nil;
	}
	return b;
}

#
# TWO TOPLEVELS, drawing alternately.
#
# scene.c's walk is ONE static struct -- Walk s[Maxwalk], depth, and the
# counters -- shared by every toplevel in the process (scene.c:678).  Every
# other case here builds one toplevel, renders it and drops it, so nothing
# tests whether walk state leaks from one toplevel to another: a depth that
# does not return to zero, or a w->scene left pointing at a freed tree.
# tkofftest(1) does not cover it either -- it has one pane.
#
# What this does is alternate `update' between two live toplevels over two
# images, which is what two windows updating actually does, and then compare
# each image against the SAME widget rendered on its own.  Interleaving must
# change nothing.  If the walk leaked between them, one or both would differ
# from its solo reference.
#
# It returns both images so the caller can check them separately: a fault
# that corrupted only the second would otherwise hide in a combined verdict.
#
painttwo(disp: ref Display): (array of byte, array of byte)
{
	offa := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
	offb := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
	topa := tk->toplevel(disp, "");
	topb := tk->toplevel(disp, "");
	if(offa == nil || offb == nil || topa == nil || topb == nil){
		sys->print("FAIL two: no images or toplevels: %r\n");
		return (nil, nil);
	}
	cmds := array[] of {
		(topa, "label .w -text Label"),
		(topb, "button .w -text Button"),
		(topa, "pack .w"),
		(topb, "pack .w"),
	};
	for(i := 0; i < len cmds; i++){
		(t, c) := cmds[i];
		r := tk->cmd(t, c);
		if(r != nil && len r > 0 && r[0] == '!'){
			sys->print("FAIL two: `%s\' -> %s\n", c, r);
			return (nil, nil);
		}
	}
	if((e := tk->putimage(topa, ". -1", offa, nil)) != nil && len e > 0){
		sys->print("FAIL two: putimage a: %s\n", e);
		return (nil, nil);
	}
	if((e = tk->putimage(topb, ". -1", offb, nil)) != nil && len e > 0){
		sys->print("FAIL two: putimage b: %s\n", e);
		return (nil, nil);
	}
	#
	# Alternate REAL redraws, not bare updates.
	#
	# An `update' on a toplevel with nothing pending does nothing, so
	# alternating bare updates interleaves no drawing at all and the
	# comparison below would pass without testing anything.  So each
	# round reconfigures the text first, which forces a repaint, and the
	# last round sets both back to what the solo references used so the
	# final images are comparable.
	#
	for(i = 0; i < 3; i++){
		tk->cmd(topa, ".w configure -text " + string i);
		tk->cmd(topa, "update");
		tk->cmd(topb, ".w configure -text " + string i);
		tk->cmd(topb, "update");
	}
	tk->cmd(topa, ".w configure -text Label");
	tk->cmd(topa, "update");
	tk->cmd(topb, ".w configure -text Button");
	tk->cmd(topb, "update");
	ba := array[W*H*3] of byte;
	bb := array[W*H*3] of byte;
	if(offa.readpixels(offa.r, ba) != len ba || offb.readpixels(offb.r, bb) != len bb){
		sys->print("FAIL two: readpixels: %r\n");
		return (nil, nil);
	}
	return (ba, bb);
}

# How many bytes differ, so a mismatch can be reported as a magnitude
# rather than just a verdict.  A near-miss and a blank image are very
# different failures.
differ(a, b: array of byte): int
{
	if(a == nil || b == nil)
		return -1;
	if(len a != len b)
		return -1;
	n := 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			n++;
	return n;
}

inked(a: array of byte): int
{
	if(a == nil)
		return 0;
	n := 0;
	for(i := 0; i < len a; i++)
		if(a[i] != byte 255)
			n++;
	return n;
}

# `render scene' / `render direct' need a toplevel to be addressed to, but
# tkviascene is a libtk-wide flag rather than per-toplevel, so any
# toplevel will do and the setting outlives it.
setmode(disp: ref Display, mode: string): int
{
	top := tk->toplevel(disp, "");
	if(top == nil)
		return 0;
	c := tk->cmd(top, "render " + mode);
	if(c != nil && len c > 0 && c[0] == '!'){
		sys->print("FAIL render %s: %s\n", mode, c);
		return 0;
	}
	got := tk->cmd(top, "render");
	if(got != mode){
		sys->print("FAIL render %s: reads back as %s\n", mode, got);
		return 0;
	}
	return 1;
}

# Three integers out of `render count' or two out of `render nodes'.
nums(s: string): list of int
{
	r: list of int;
	i := 0;
	while(i < len s){
		while(i < len s && (s[i] == ' ' || s[i] == '\t'))
			i++;
		j := i;
		while(j < len s && s[j] >= '0' && s[j] <= '9')
			j++;
		if(j == i)
			break;
		r = int s[i:j] :: r;
		i = j;
	}
	# reverse
	o: list of int;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

#
# A Tk command whose failure must not pass unnoticed: a configure that
# did not take leaves a measurement counting fewer items than it says.
#
cfg(top: ref Tk->Toplevel, cmd: string)
{
	r := tk->cmd(top, cmd);
	if(r != nil && len r > 0 && r[0] == '!')
		sys->print("tkscenetest: `%s\' -> %s\n", cmd, r);
}

counts(disp: ref Display, which: string): list of int
{
	top := tk->toplevel(disp, "");
	if(top == nil)
		return nil;
	return nums(tk->cmd(top, "render " + which));
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("tkscenetest: load $Draw: %r\n");
		raise "fail:load";
	}
	tk = load Tk Tk->PATH;
	if(tk == nil){
		sys->print("tkscenetest: load $Tk: %r\n");
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose++;

	# Under a window system take its Display; with none -- a kernel with
	# no display attached, which is the case this exists for -- allocate
	# one, as the board's own probe does.
	disp: ref Display;
	if(ctxt != nil)
		disp = ctxt.display;
	else
		disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("tkscenetest: no Display: %r\n");
		raise "fail:display";
	}

	#
	# One of every widget kind the node path has a conversion for, and
	# then the STATES those conversions have their own nodes for.  A
	# default-options-only suite passes while every selected, focused,
	# disabled or populated widget is broken -- which is tkofftest(1)'s
	# coverage lesson, and the plan records each of these states as a
	# separate conversion with its own node kinds.
	#
	# Each case is a name and the commands to build it.  `pack .w' last,
	# always, because a widget must exist before it is packed.
	#
	names := array[] of {
		# plain, default options
		"label", "button", "frame", "entry", "scale", "scrollbar",
		"listbox", "canvas", "text", "menubutton", "checkbutton",
		"radiobutton",
		# the states with their own node kinds
		"entry with a selection", "entry -show", "disabled button",
		"canvas with items", "listbox with a selection",
		"text with content", "scale at a value",
		"scrollbar part-scrolled", "non-default font", "frame -relief",
		# the four the BUGS section used to list as uncovered
		"focused entry", "clipped label", "non-default colours",
		"canvas -fill by name", "canvas polygon", "label -bitmap",
		# the three coverage gaps BUGS still listed
		"listbox twelve items", "scrolled listbox view",
		"coloured button", "grid geometry",
	};
	cases := array[] of {
		list of {"label .w -text Label", "pack .w"},
		list of {"button .w -text Button", "pack .w"},
		list of {"frame .w -width 80 -height 30", "pack .w"},
		list of {"entry .w -width 60", "pack .w"},
		list of {"scale .w -from 0 -to 10", "pack .w"},
		list of {"scrollbar .w", "pack .w"},
		list of {"listbox .w -width 120 -height 44", "pack .w"},
		list of {"canvas .w -width 80 -height 30", "pack .w"},
		list of {"text .w -width 120 -height 44", "pack .w"},
		list of {"menubutton .w -text Menu", "pack .w"},
		list of {"checkbutton .w -text Check", "pack .w"},
		list of {"radiobutton .w -text Radio", "pack .w"},

		# A selection band is tkscenetextsel()'s five colour nodes plus
		# glyph runs, and no default widget reaches it.
		list of {"entry .w -width 60", "pack .w",
			".w insert 0 selected", ".w selection from 0",
			".w selection to 8"},
		# -show replaces every rune, so the glyph run is not the text.
		list of {"entry .w -width 60 -show *", "pack .w",
			".w insert 0 secret"},
		# Disabled draws in a different colour through the same nodes.
		list of {"button .w -text Button -state disabled", "pack .w"},
		# Canvas items are their own conversions: a rectangle, a line,
		# an oval and a string, so four node kinds in one image.
		list of {"canvas .w -width 140 -height 50", "pack .w",
			".w create rectangle 5 5 60 30 -fill red",
			".w create line 10 40 130 45 -width 2",
			".w create oval 70 5 120 30 -fill blue",
			".w create text 20 45 -text item"},
		# A listbox selection band, which is not the entry's.
		list of {"listbox .w -width 120 -height 44", "pack .w",
			".w insert end one", ".w insert end two",
			".w insert end three", ".w selection set 1 1"},
		# Text with content reaches the text widget's glyph layout
		# rather than an empty box.
		list of {"text .w -width 130 -height 44", "pack .w",
			".w insert end 'two lines\nof text"},
		# A scale away from its minimum moves the slider node.
		list of {"scale .w -from 0 -to 10 -length 120", "pack .w",
			".w set 7"},
		# A part-scrolled scrollbar is a different geometry from a
		# full one, and the full one is the default.
		list of {"scrollbar .w -orient horizontal", "pack .w",
			".w set 0.25 0.6"},
		# A non-default font makes a wrong-font node visible; with
		# every widget in one face it would still have drawn.
		list of {"label .w -text Font -font /fonts/pelm/latin1.9.font",
			"pack .w"},
		# A relief is the border conversion rather than the fill.
		list of {"frame .w -width 80 -height 30 -relief sunken -borderwidth 2",
			"pack .w"},

		# A focused entry draws its ring, and draws it BEFORE the
		# border: entry.c:537 says a ring after the border puts a
		# square corner where the border has just cut the widget away.
		# tkhaskeyfocus() gates it (entry.c:513), so an unfocused
		# entry never reaches either path.
		list of {"entry .w -width 50", "pack .w",
			".w insert 0 focus", "focus .w"},

		# Bigger than the image it is rendered into, so the right and
		# bottom are clipped.  Nothing else here crosses a clip
		# boundary, and a node that describes a box it does not
		# entirely fill is the case a backend has to get right.
		list of {"label .w -text clipped -width 400 -height 200",
			"pack .w"},

		# A colour scheme that is not the default, by NAME rather than
		# by #RRGGBB -- which is the branch of tkparsecolor that
		# 7l's undefined all-ones mask sat in.  Named colours are
		# therefore load-bearing coverage, not decoration.
		list of {"label .w -text colours -background red -foreground white",
			"pack .w"},

		# The same branch again from the canvas side, kept separate
		# because a canvas item's fill and a widget's background are
		# different conversions that happen to share the parser.
		list of {"canvas .w -width 120 -height 40", "pack .w",
			".w create rectangle 5 5 110 35 -fill green"},

		# A FILLED POLYGON, which is TkNpolyfill -- the node kind a
		# menu cascade's arrow uses (tktriangle(), one fillpoly() of
		# three points).  Nothing else here emits one: the canvas case
		# above has a rectangle, a line, an oval and a string, and a
		# posted menu is out of this harness's reach.  So the node kind
		# is covered even though the widget that normally produces it
		# is not.
		list of {"canvas .w -width 120 -height 40", "pack .w",
			".w create polygon 10 35 60 5 110 35 -fill blue"},

		# TkNtexture, which no other case emits.  The node names a
		# FILE rather than carrying pixels -- which is why an image
		# that came from a file descriptor is the one thing the
		# vocabulary cannot describe -- so this needs a real path in
		# the tree.  A one-bit icon painted THROUGH in the foreground
		# colour is how the chrome's own artwork is drawn.  A bare name
		# resolves to /icons/tk/<name> (parse.c:845), not to an
		# absolute path -- an absolute one gives !failed to load bitmap.
		list of {"label .w -bitmap audio.bit", "pack .w"},

		# The reference for the scrolled case below: identical in every
		# respect except the yview, so the difference between them is
		# the SCROLL and nothing else.  Referencing the scrolled one
		# against the plain `listbox' case instead gave 102 bytes,
		# which is a real difference that could not be attributed --
		# that case has no items and a different size.
		list of {"listbox .w -width 120 -height 44", "pack .w",
			".w insert end i0",
			".w insert end i1",
			".w insert end i2",
			".w insert end i3",
			".w insert end i4",
			".w insert end i5",
			".w insert end i6",
			".w insert end i7",
			".w insert end i8",
			".w insert end i9",
			".w insert end i10",
			".w insert end i11",
			".w selection set 3 3"},

		# A listbox scrolled so its VIEW starts partway down, which is
		# a different thing from a part-scrolled scrollbar: the
		# scrollbar's slider geometry changes, a scrolled listbox's
		# item layout and selection band move with the view.
		#
		# THIS CASE SKIPS, and the reason is not settled.
		#
		# Nothing scrolls it.  `yview moveto 0.5', `yview moveto 1.0',
		# `yview 6' and `yview 2' all leave the rendered pixels
		# IDENTICAL to the unscrolled reference above -- twelve items
		# in a listbox packed into a 160x60 image -- and none of them
		# returns an error, so the per-command reply check cannot see
		# it either.  (`yview 2' additionally takes the bare-index
		# branch at listb.c:820 rather than a verb, which is accepted
		# silently.)
		#
		# listb.c:719 clamps yelem to nitem - bh and then to 0, which
		# is correct when everything fits; at twelve items in about
		# sixty pixels it should not apply, so that is not obviously
		# the explanation.  Whether this is a libtk defect or
		# something about a listbox packed into an offscreen image
		# that this harness cannot drive, I have not determined, and
		# I am not guessing in a comment.
		#
		# The case stays, skipping, with that reason.  A skip that
		# says "indistinguishable from its reference, so it covers
		# nothing" is the correct outcome for a case that cannot be
		# made to differ -- better than deleting it, which loses the
		# question, and better than passing it, which would claim
		# coverage of a scrolled view this does not have.
		list of {"listbox .w -width 120 -height 44", "pack .w",
			".w insert end i0",
			".w insert end i1",
			".w insert end i2",
			".w insert end i3",
			".w insert end i4",
			".w insert end i5",
			".w insert end i6",
			".w insert end i7",
			".w insert end i8",
			".w insert end i9",
			".w insert end i10",
			".w insert end i11",
			".w selection set 3 3",
			".w yview moveto 0.5"},

		# A non-default colour on something that is not a label, since
		# every widget kind resolves its own colours and a label's
		# path is the one already covered.
		list of {"button .w -text Colour -background blue -foreground yellow",
			"pack .w"},

		# grid rather than pack, which is a different geometry manager
		# reaching the same node kinds through different placement --
		# so a widget at a grid cell must land where one packed does
		# not, and the comparison is between the two PATHS at that
		# placement rather than against a packed reference.
		list of {"label .w -text grid", "frame .f", "label .f.a -text a",
			"label .f.b -text b", "grid .f.a -row 0 -column 0",
			"grid .f.b -row 1 -column 1", "pack .f", "pack .w"},
	};
	if(len names != len cases){
		sys->print("tkscenetest: %d names for %d cases\n", len names, len cases);
		raise "fail:internal";
	}
	#
	# Cases that need something the environment may not have, and which
	# must therefore PROVE they got it.  Indexed as names/cases are.
	#
	# The font case needs it.  A face that cannot be opened is reported
	# -- `!failed to open font' -- so the per-command check catches that
	# much.  What it does not catch is a font that opens and draws the
	# SAME, which is what asking for the default face by another name
	# would do, and then the case passes while covering nothing about the
	# font-name node.  So the case must differ from the one it is
	# supposed to differ from, and is skipped when it does not: on the
	# Pi 3B kernel the root carries exactly one font
	# (/fonts/pelm/unicode.8.font, which is also Tk's default), so there
	# is no second face there and skipping is the honest outcome.
	#
	#
	# Each of these must come out DIFFERENT from the plain case it is a
	# variation of, or it is covering nothing and is skipped.  The font
	# case taught this; the rest are held to the same standard rather
	# than trusted because they are newer.  `focus .w' setting the focus,
	# a 400x200 label actually being clipped by a 160x60 image, and a
	# named colour reaching the widget at all are each assumptions, and
	# an assumption that is cheap to check should be checked.
	#
	optional := array[len names] of {* => -1};
	base := array[] of {
		("non-default font",        "label"),
		("focused entry",           "entry"),
		("clipped label",           "label"),
		("non-default colours",     "label"),
		("canvas -fill by name",    "canvas"),
		("canvas polygon",          "canvas"),
		("label -bitmap",           "label"),
		("scrolled listbox view",   "listbox twelve items"),
		# These were NOT checked against a base, which is how four
		# five-pixel-tall widgets passed as covered: a listbox or text
		# widget given -width 12 -height 3 is 14x5 PIXELS here, because
		# those options are pixels and not characters, so the case drew
		# nothing but the toplevel's background and `inked() > 0' was
		# satisfied by that.  Everything that is a variation of another
		# case is now held to the rule.
		("listbox with a selection", "listbox"),
		("text with content",       "text"),
		("entry with a selection",  "entry"),
		("entry -show",             "entry"),
		("disabled button",         "button"),
		("canvas with items",       "canvas"),
		("scale at a value",        "scale"),
		("scrollbar part-scrolled", "scrollbar"),
		("frame -relief",           "frame"),
		("listbox twelve items",    "listbox"),
		("coloured button",         "button"),
		("grid geometry",           "label"),
	};
	for(bi := 0; bi < len base; bi++){
		(who, against) := base[bi];
		wi := ai := -1;
		for(oi := 0; oi < len names; oi++){
			if(names[oi] == who)
				wi = oi;
			if(names[oi] == against && ai < 0)
				ai = oi;
		}
		if(wi < 0 || ai < 0){
			sys->print("tkscenetest: internal: no case `%s\' or `%s\'\n", who, against);
			raise "fail:internal";
		}
		optional[wi] = ai;
	}

	sys->print("tkscenetest: %d cases, %dx%d RGB24\n", len cases, W, H);

	# Baseline: the direct path, which is the default.
	if(!setmode(disp, "direct"))
		raise "fail:render direct";
	dpix := array[len cases] of array of byte;
	for(i := 0; i < len cases; i++){
		dpix[i] = paint(disp, names[i], cases[i]);
		if(optional[i] >= 0){
			# It had to come out different from the case it names.
			d := differ(dpix[i], dpix[optional[i]]);
			if(dpix[i] == nil || d == 0){
				why := "indistinguishable from `" + names[optional[i]] +
					"\' here, so it covers nothing";
				if(dpix[i] == nil)
					why = "could not be built here (see above)";
				skip(sys->sprint("%s: %s", names[i], why));
				dpix[i] = nil;
				continue;
			}
			report(1, sys->sprint("%s really differs from `%s\' (%d bytes)",
				names[i], names[optional[i]], d));
		}
		report(dpix[i] != nil && inked(dpix[i]) > 0,
			sys->sprint("direct: %s drew something (%d bytes of ink)",
				names[i], inked(dpix[i])));
	}

	# Two toplevels drawing alternately, DIRECT arm.  Kept only as the
	# reference for the scene arm below: the walk is scene-path machinery,
	# so interleaving on the direct path cannot test it and this pair is
	# not the interesting comparison.
	(dtwoa, dtwob) := painttwo(disp);
	if(dtwoa != nil && dtwob != nil && dpix[0] != nil && dpix[1] != nil){
		da := differ(dtwoa, dpix[0]);
		db := differ(dtwob, dpix[1]);
		report(da == 0 && db == 0,
			sys->sprint("direct: two toplevels alternating draw what each draws alone (%d and %d bytes differ)", da, db));
	}else
		report(0, "two toplevels and their solo references all rendered");

	# The deep nest, direct arm.  The batching figure cannot be taken
	# here: `render count' counts TREES, and the direct path builds
	# none, so it answers 0 in 0 -- which is what it did when this
	# measurement was first put in the wrong round.
	ddeep := paintnest(disp, Deep);
	report(ddeep != nil && inked(ddeep) > 0,
		sys->sprint("direct: a nest %d deep drew something (%d bytes of ink)", Deep, inked(ddeep)));

	# The posted menu, its own path because it needs a Screen.
	dmenu := paintmenu(disp, 1);
	dnomenu := paintmenu(disp, 0);
	dmd := differ(dmenu, dnomenu);
	report(dmd > 0,
		sys->sprint("a POSTED menu differs from the same menu unposted (%d bytes) -- so the menu really drew",
			dmd));

	# NEGATIVE CONTROL for the comparison itself: two DIFFERENT widgets
	# must not compare equal.  Without this, a differ() that always
	# returned 0 would make every identity check below pass.
	if(len cases >= 2){
		d := differ(dpix[0], dpix[1]);
		report(d > 0, sys->sprint("control: a label and a button differ (%d bytes)", d));
	}

	# Now the node path.
	if(!setmode(disp, "scene"))
		raise "fail:render scene";

	spix := array[len cases] of array of byte;
	for(i = 0; i < len cases; i++)
		if(dpix[i] != nil)	# a dropped case is not re-run: it would
			spix[i] = paint(disp, names[i], cases[i]);
					# only reprint its own setup failure

	#
	# ONE READ PER ROUND.  `render count', `render nodes' and `render
	# bounds' all call tkwalkreset() (libtk/utils.c), so they share one
	# set of accumulators and EACH READ CLEARS ALL THREE.  Reading two in
	# a row gives the second one zero -- which is how the first version
	# of this test reported "0 nodes that mark pixels" immediately after
	# `render count' had said the node path ran.  So each read gets its
	# own rendering round.
	#

	# THE CONTROL THAT MAKES THE IDENTITY MEAN ANYTHING: did the node
	# path actually run?  runs/widgets/nodes must all be non-zero, or the
	# agreement below is agreement between two direct renders.
	c := counts(disp, "count");
	runs := widgets := nodes := 0;
	if(c != nil){
		runs = hd c;
		if(tl c != nil){
			widgets = hd tl c;
			if(tl tl c != nil)
				nodes = hd tl tl c;
		}
	}
	report(runs > 0 && widgets > 0 && nodes > 0,
		sys->sprint("the node path RAN: %d trees, %d widgets, %d nodes", runs, widgets, nodes));

	# Fresh round: every node that marks pixels must describe its own
	# box, which is the one property the vocabulary exists to provide.
	for(i = 0; i < len cases; i++)
		if(dpix[i] != nil)
			paint(disp, names[i], cases[i]);
	n := counts(disp, "nodes");
	drawn := undesc := 0;
	if(n != nil){
		drawn = hd n;
		if(tl n != nil)
			undesc = hd tl n;
	}
	report(drawn > 0 && undesc == 0,
		sys->sprint("of %d nodes that mark pixels, %d describe no box", drawn, undesc));

	# Fresh round again: the union the trees marked must be a non-empty
	# box inside the image.  A described frame that says it drew nothing,
	# or says it drew outside the image, is useless to a backend.
	for(i = 0; i < len cases; i++)
		if(dpix[i] != nil)
			paint(disp, names[i], cases[i]);
	bb := counts(disp, "bounds");
	bok := 0;
	bs := "no reply";
	if(bb != nil && len bb == 0)
		bs = "empty";
	if(bb != nil){
		v := array[4] of {* => -1};
		k := 0;
		for(l := bb; l != nil && k < 4; l = tl l)
			v[k++] = hd l;
		if(k == 4){
			bs = sys->sprint("%d %d %d %d", v[0], v[1], v[2], v[3]);
			bok = v[2] > v[0] && v[3] > v[1]
				&& v[0] >= 0 && v[1] >= 0
				&& v[2] <= W && v[3] <= H;
		}
	}
	report(bok, sys->sprint("the trees marked a non-empty box inside the image (%s)", bs));

	#
	# Did the walk's Maxwalk fallback actually fire?
	#
	# My first predicate was "batching is lost, so widgets-per-tree
	# falls", and it was WRONG about the mechanism: the ratio is 1.00 at
	# every depth, because tkwalkopen() flushes the enclosing walk's
	# pending tree before pushing (scene.c:720), so a nested window
	# always gets a tree of its own and there is no batching here to
	# lose.  The figure that does say it is the TREE COUNT SATURATING:
	# one walk level per nested window up to Maxwalk, and none after, so
	# a nest 10 deep yields 8 trees where it would otherwise yield 11.
	#
	# `render count' resets, so the depths are measured in separate
	# rounds.
	#
	# Three depths, not two.  With only a shallow and a deep point, a
	# constant 8 unrelated to depth would satisfy "capped at Maxwalk" --
	# so a MIDDLE depth below the cap has to be shown to scale with
	# depth, which is what distinguishes a cap from a constant.
	tk->cmd(tk->toplevel(disp, ""), "render count");	# reset
	paintnest(disp, 2);
	cs := counts(disp, "count");
	paintnest(disp, Mid);
	cm := counts(disp, "count");
	sdeep := paintnest(disp, Deep);
	cd := counts(disp, "count");
	ratio := "no reply";
	fellback := 0;
	if(cs != nil && tl cs != nil && cd != nil && tl cd != nil){
		st := hd cs;
		dt := hd cd;
		mt := 0;
		if(cm != nil)
			mt = hd cm;
		ratio = sys->sprint("depth 2 -> %d trees, depth %d -> %d (unsaturated %d), depth %d -> %d (unsaturated %d, Maxwalk %d)",
			st, Mid, mt, Mid+1, Deep, dt, Deep+1, Maxwalk);
		# scales with depth below the cap, and stops at it above:
		# a constant would fail the middle test, and no cap at all
		# would fail the last.
		fellback = st == 3 && mt == Mid+1 && dt == Maxwalk;
	}
	report(fellback, sys->sprint("tree count scales with depth then CAPS at Maxwalk -- %s", ratio));

	if(ddeep != nil && sdeep != nil){
		dn := differ(ddeep, sdeep);
		report(dn == 0, sys->sprint("scene == direct: a nest %d deep, past Maxwalk %d (%d bytes differ)", Deep, Maxwalk, dn));
	}else
		report(0, "a nest past Maxwalk rendered in both paths");

	#
	# TWO TOPLEVELS, SCENE ARM -- the one that tests the walk.
	#
	# scene.c's walk is a single static struct shared by every toplevel,
	# so this is where interleaved drawing could leak state: a depth that
	# does not return to zero, or a w->scene left pointing at a tree the
	# flush has freed.  Three comparisons, because they fail differently:
	# each image against the same widget rendered SOLO through the node
	# path, and the interleaved pair against the interleaved direct pair.
	#
	# Did this case build trees at all?  painttwo() is a separate code
	# path and the global count was read before it ran, so its arm had no
	# evidence of its own -- the identity below would pass if both arms
	# had somehow taken the direct path.  One read of its own, which also
	# resets, so it sits after the nest block has taken its figures.
	tk->cmd(tk->toplevel(disp, ""), "render count");	# reset
	(stwoa, stwob) := painttwo(disp);
	ct := counts(disp, "count");
	ctrees := 0;
	if(ct != nil)
		ctrees = hd ct;
	report(ctrees > 0,
		sys->sprint("the two-toplevel case builds trees (%d)", ctrees));
	if(stwoa != nil && stwob != nil && spix[0] != nil && spix[1] != nil){
		sa := differ(stwoa, spix[0]);
		sb := differ(stwob, spix[1]);
		report(sa == 0 && sb == 0,
			sys->sprint("scene: two toplevels alternating draw what each draws alone (%d and %d bytes differ)", sa, sb));
		if(dtwoa != nil && dtwob != nil){
			ia := differ(stwoa, dtwoa);
			ib := differ(stwob, dtwob);
			report(ia == 0 && ib == 0,
				sys->sprint("scene == direct with two toplevels interleaved (%d and %d bytes differ)", ia, ib));
		}
	}else
		report(0, "two toplevels rendered through the node path");

	smenu := paintmenu(disp, 1);
	if(dmenu != nil && smenu != nil){
		dm := differ(dmenu, smenu);
		report(dm == 0, sys->sprint("scene == direct: a posted menu with a cascade (%d bytes differ)", dm));
	}else
		report(0, "the posted menu was rendered in both paths");

	# And the identity itself.
	for(i = 0; i < len cases; i++){
		if(dpix[i] == nil)
			continue;	# dropped: reported as skipped or failed already
		d := differ(dpix[i], spix[i]);
		report(d == 0, sys->sprint("scene == direct: %s (%d bytes differ)", names[i], d));
	}

	#
	# Item 1.2's measurement: is there anything for a retained SCENE to
	# save in a canvas?  The canvas already keeps its pixels in
	# c->image and guards its item loop with the dirty region, so a
	# canvas that nothing has changed should walk NO items.  Counted
	# rather than read off the source.
	#
	ctop := tk->toplevel(disp, "");
	if(ctop != nil){
		coff := disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
		tk->cmd(ctop, "canvas .c -width 80 -height 30");
		#
		# The CREATE replies are the item ids.  Assuming 1 and 2
		# gave "!bad/no matching tag" on the second, so one of the
		# two configures below silently did nothing.  Checking the
		# replies then found a second: "rect" is not an item type
		# here -- it is "rectangle" -- so the rectangle had never
		# been created either and the canvas held ONE item while the
		# message said two.  This test's own header says to check
		# every reply, and this measurement had not.
		#
		id1 := tk->cmd(ctop, ".c create rectangle 5 5 40 20 -fill red");
		id2 := tk->cmd(ctop, ".c create text 10 25 -text hi -fill red");
		tk->cmd(ctop, "pack .c");
		if(id1 == nil || len id1 == 0 || id1[0] == '!'
		|| id2 == nil || len id2 == 0 || id2[0] == '!')
			sys->print("tkscenetest: canvas item create failed: %s %s\n", id1, id2);
		if(coff != nil)
			tk->putimage(ctop, ". -1", coff, nil);
		#
		# SEQUENCE MATTERS and the first attempt got it wrong: `pack'
		# lays out and paints, so resetting after it and then calling
		# update measured a canvas that had ALREADY been drawn and
		# reported 0 for the first paint.  Paint first, then reset,
		# then ask the two questions that matter.
		#
		tk->cmd(ctop, "update");		# whatever pack left pending
		tk->cmd(ctop, "render items");		# reset AFTER the first paint
		tk->cmd(ctop, "update");		# nothing changed
		n2 := hd nums(tk->cmd(ctop, "render items"));
		cfg(ctop, ".c itemconfigure " + id1 + " -fill blue");
		tk->cmd(ctop, "update");
		n3 := hd nums(tk->cmd(ctop, "render items"));
		cfg(ctop, ".c itemconfigure " + id1 + " -fill green");
		cfg(ctop, ".c itemconfigure " + id2 + " -fill green");
		tk->cmd(ctop, "update");
		n4 := hd nums(tk->cmd(ctop, "render items"));
		sys->print("tkscenetest: canvas items drawn: unchanged repaint %d, one item changed %d, two changed %d (of 2 items)\n",
			n2, n3, n4);
		#
		# How far does the damage rectangle over-collect?  Changing
		# ONE item re-walks every item whose box meets c->update, and
		# c->update is a single rectangle.  So the question 1.2 turns
		# on is whether that is a few neighbours or the whole canvas,
		# and the answer must depend on the arrangement -- hence two
		# of them rather than one number.
		#
		spread := tk->toplevel(disp, "");
		if(spread != nil){
			soff := disp.newimage(Rect((0,0),(400,100)), draw->RGB24, 0, Draw->White);
			tk->cmd(spread, "canvas .c -width 380 -height 80");
			tk->cmd(spread, "pack .c");
			ids := array[20] of string;
			for(k := 0; k < 20; k++)
				ids[k] = tk->cmd(spread, sys->sprint(".c create rectangle %d 10 %d 30 -fill red",
					5 + k*18, 15 + k*18));
			if(soff != nil)
				tk->putimage(spread, ". -1", soff, nil);
			tk->cmd(spread, "update");
			tk->cmd(spread, "render items");
			cfg(spread, ".c itemconfigure " + ids[0] + " -fill blue");
			tk->cmd(spread, "update");
			sp1 := hd nums(tk->cmd(spread, "render items"));
			cfg(spread, ".c itemconfigure " + ids[10] + " -fill blue");
			tk->cmd(spread, "update");
			sp2 := hd nums(tk->cmd(spread, "render items"));
			sys->print("tkscenetest: 20 spread items, change one: %d re-walked at the edge, %d in the middle\n",
				sp1, sp2);
		}
	}

	#
	# The per-type table, for item 1.1 of doc/scene-graph-plan.ms: a
	# retained tree is only possible over a subtree no DIRECT painter
	# enters, so what is wanted is the list of types that paint without
	# joining -- not a ratio, which would average over a population
	# whose members behave differently.
	#
	# Printed rather than asserted.  It is a reading list: a type with
	# joins of 0 either paints directly or paints nothing, and only
	# reading the widget separates those.  Asserting on it would be
	# asserting on whatever this test happens to exercise.
	#
	# Reset first and repaint, because the cases above reset the
	# counters twice for their own checks, so whatever survives to here
	# is a tail of the run and not its population.
	#
	tk->cmd(tk->toplevel(disp, ""), "render scene");
	tk->cmd(tk->toplevel(disp, ""), "render types");	# reset: state the population
	for(i = 0; i < len cases; i++)
		paint(disp, names[i], cases[i]);
	paintmenu(disp, 1);		# so separator and cascade are IN the population
	t := tk->cmd(tk->toplevel(disp, ""), "render types");
	if(t != nil && len t > 0 && t[0] != '!')
		sys->print("tkscenetest: types (name drew joined): %s\n", t);

	if(skipped > 0)
		sys->print("tkscenetest: %d ok, %d fail, %d skipped\n", ok, fail, skipped);
	else
		sys->print("tkscenetest: %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:tkscenetest";
}
