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
	Display, Image, Rect, Point: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;

Tkscenetest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ok, fail: int;
verbose: int;

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

# Lay out one widget specification into a fresh image and hand back its
# pixels.  A toplevel of its own each time, because reconfiguring one and
# reading it again measures whatever the reconfigure happened to repaint,
# which is not the question.  (The idiom is raspi3binit.b's.)
paint(disp: ref Display, spec: string): array of byte
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
	c := tk->cmd(top, spec);
	if(c != nil && len c > 0 && c[0] == '!'){
		sys->print("FAIL %s: %s\n", spec, c);
		return nil;
	}
	if((c = tk->cmd(top, "pack .w")) != nil && len c > 0 && c[0] == '!'){
		sys->print("FAIL pack: %s\n", c);
		return nil;
	}
	if((c = tk->putimage(top, ". -1", off, nil)) != nil && len c > 0){
		sys->print("FAIL putimage: %s\n", c);
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

	# One of every widget kind the node path has a conversion for.  A
	# single label would pass while every other widget was broken --
	# the coverage lesson from tkofftest(1).
	specs := array[] of {
		"label .w -text Label",
		"button .w -text Button",
		"frame .w -width 80 -height 30",
		"entry .w -width 60",
		"scale .w -from 0 -to 10",
		"scrollbar .w",
		"listbox .w -width 10 -height 2",
		"canvas .w -width 80 -height 30",
		"text .w -width 10 -height 2",
		"menubutton .w -text Menu",
		"checkbutton .w -text Check",
		"radiobutton .w -text Radio",
	};

	sys->print("tkscenetest: %d widget kinds, %dx%d RGB24\n", len specs, W, H);

	# Baseline: the direct path, which is the default.
	if(!setmode(disp, "direct"))
		raise "fail:render direct";
	dpix := array[len specs] of array of byte;
	for(i := 0; i < len specs; i++){
		dpix[i] = paint(disp, specs[i]);
		report(dpix[i] != nil && inked(dpix[i]) > 0,
			sys->sprint("direct: %s drew something (%d bytes of ink)",
				specs[i], inked(dpix[i])));
	}

	# NEGATIVE CONTROL for the comparison itself: two DIFFERENT widgets
	# must not compare equal.  Without this, a differ() that always
	# returned 0 would make every identity check below pass.
	if(len specs >= 2){
		d := differ(dpix[0], dpix[1]);
		report(d > 0, sys->sprint("control: a label and a button differ (%d bytes)", d));
	}

	# Now the node path.
	if(!setmode(disp, "scene"))
		raise "fail:render scene";

	spix := array[len specs] of array of byte;
	for(i = 0; i < len specs; i++)
		spix[i] = paint(disp, specs[i]);

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
	for(i = 0; i < len specs; i++)
		paint(disp, specs[i]);
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
	for(i = 0; i < len specs; i++)
		paint(disp, specs[i]);
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

	# And the identity itself.
	for(i = 0; i < len specs; i++){
		d := differ(dpix[i], spix[i]);
		report(d == 0, sys->sprint("scene == direct: %s (%d bytes differ)", specs[i], d));
	}

	sys->print("tkscenetest: %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:tkscenetest";
}
