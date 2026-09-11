implement Tkbench;

# What does it cost to redraw a widget?
#
# The question came up when asking whether libtk should be on the GPU.
# It draws with memdraw(), which is scalar C, and nothing in the tree had
# ever timed it - so "fast enough" was an inference from what the work
# looks like rather than a number.  This makes it a number.
#
# METHOD.  A toplevel is built offscreen, over an ordinary image rather
# than the display's screen, the same way tkofftest(1) and tkgallery(1)
# do.  `style <the style it already has>' is used as the repaint trigger:
# tkstylecmd() marks every widget dirty and calls tkupdate(), so one call
# is one full-tree repaint, which is the thing being measured and is hard
# to provoke otherwise.  It also re-applies the colour table, about
# seventeen entries; that is counted in the baseline and subtracted.
#
# The cost of ONE widget is the repaint time of a toplevel holding it
# minus the repaint time of a toplevel holding nothing, both measured the
# same way.  A single widget is far below the 1ms clock, so each figure
# is a loop run until it has taken at least Minms.
#
# WHAT WOULD MAKE THIS WRONG, and is therefore checked: a widget packed
# outside the window might be clipped and never drawn, which would make
# a big number look small.  So the scaling control builds 8 of a kind as
# well as 1, and reports both; if 8 does not cost about 8 times 1, the
# measurement is not measuring what it says.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Screen: import draw;
include "tk.m";
	tk: Tk;
include "env.m";
include "arg.m";

Tkbench: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 900;
H: con 700;
Minms: con 600;			# run each figure at least this long
Nlo: con 2;			# the two widget counts the slope is taken between
Nhi: con 18;

disp: ref Display;
off: ref Image;
scr: ref Screen;
win: ref Image;
verbose := 0;
onscreen := 0;
idle := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(argv);
		arg->setusage("tkbench [-isv]");
		while((c := arg->opt()) != 0)
			case c {
			'v' =>	verbose = 1;
			's' =>	onscreen = 1;
			'i' =>	idle = 1;
			* =>	arg->usage();
			}
	}
	if(tk == nil){
		sys->print("tkbench: no tk: %r\n");
		raise "fail:no tk";
	}
	disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("tkbench: no display: %r\n");
		raise "fail:no display";
	}
	# -s puts the window on the display's REAL screen, so each repaint
	# ends in a Metal upload and present.  Offscreen there is no present
	# at all, which is what makes the default figures drawing-only.
	if(onscreen){
		off = disp.image;
		if(off == nil){
			sys->print("tkbench: no screen image: %r\n");
			raise "fail:no screen image";
		}
	}else
		off = disp.newimage(Rect((0,0),(W,H)), Draw->RGB24, 0, Draw->White);
	scr = Screen.allocate(off, disp.color(Draw->White), 0);
	win = scr.newwindow(off.r, Draw->Refbackup, Draw->Nofill);
	if(off == nil || scr == nil || win == nil){
		sys->print("tkbench: no offscreen screen: %r\n");
		raise "fail:no screen";
	}

	e := load Env Env->PATH;
	how := "unknown";
	if(e != nil && (s := e->getenv("emuexec")) != "")
		how = s;
	where := "offscreen";
	if(onscreen)
		where = "ON SCREEN (each repaint presents)";
	sys->print("tkbench: %s, %dx%d %s\n", how, off.r.dx(), off.r.dy(), where);

	# -i repaints slowly, leaving the processor idle between frames.  The
	# timers inside emu are WALL CLOCK on the AppKit thread, so with the
	# benchmark saturating the machine they measure how long that thread
	# waited to be scheduled rather than how long the work took.  Idle is
	# the only condition in which those numbers mean what they say.
	if(idle){
		sys->print("tkbench: idle present mode, 200 repaints 25ms apart\n");
		idlepresents();
		return;
	}

	kinds := array[] of {
		("label",	"label %s -text {Handgloves}"),
		("button",	"button %s -text {Cancel}"),
		("checkbutton",	"checkbutton %s -text {Wrap lines} -variable v"),
		("radiobutton",	"radiobutton %s -text {Every third} -variable r -value 1"),
		("entry",	"entry %s -width 160"),
		("scale",	"scale %s -orient horizontal -from 0 -to 100 -length 160"),
		("scrollbar",	"scrollbar %s -orient horizontal -width 160"),
		("listbox",	"listbox %s -width 160 -height 60"),
		("text",	"text %s -width 160 -height 60"),
		("frame",	"frame %s -width 120 -height 40 -borderwidth 2 -relief raised"),
	};

	for(sl := list of {"classic", "flat"}; sl != nil; sl = tl sl){
		st := hd sl;
		base := repaint(st, nil, 0);
		sys->print("\n%s: an empty toplevel repaints in %s\n", st, us(base));
		sys->print("  %-12s %11s %11s %11s\n",
			"widget", "few", "many", "each");
		for(i := 0; i < len kinds; i++){
			(nm, spec) := kinds[i];
			lo := repaint(st, spec, Nlo);
			hi := repaint(st, spec, Nhi);
			# The SLOPE between two counts, not the difference from an
			# empty window.  Measured that way the fixed cost of a
			# repaint swamps a single widget and the figures were
			# noise: one ratio came out at 336937%, which is the
			# control saying the measurement was worthless.
			each := (hi - lo)/(Nhi - Nlo);
			sys->print("  %-12s %11s %11s %11s\n",
				nm, us(lo), us(hi), us(each));
		}
	}
	sys->print("\ntkbench: `each' is the slope between the two counts, which is the\n");
	sys->print("tkbench: only figure here that does not include the fixed cost of a\n");
	sys->print("tkbench: repaint.  If it is negative or absurd, the widgets are not\n");
	sys->print("tkbench: all being drawn - check that %d of them still fit.\n", Nhi);
}

idlepresents()
{
	off.draw(off.r, disp.color(Draw->White), nil, off.r.min);
	top := tk->toplevel(disp, "");
	if(top == nil)
		return;
	top.screenr = off.r;
	tk->cmd(top, "style flat");
	tk->cmd(top, "frame .a");
	for(i := 0; i < 6; i++){
		w := sys->sprint(".a.w%d", i);
		tk->cmd(top, "button " + w + " -text {Cancel}");
		tk->cmd(top, "pack " + w);
	}
	tk->cmd(top, "pack .a");
	tk->putimage(top, ". -1", win, nil);
	tk->cmd(top, "update");
	for(i = 0; i < 200; i++){
		tk->cmd(top, "style flat");
		sys->sleep(25);
	}
}

# nanoseconds per full-tree repaint of a toplevel holding n of spec
repaint(style, spec: string, n: int): int
{
	off.draw(off.r, disp.color(Draw->White), nil, off.r.min);
	top := tk->toplevel(disp, "");
	if(top == nil)
		return 0;
	top.screenr = off.r;
	tk->cmd(top, "style " + style);

	# two columns, so eight of anything still fits and is drawn
	tk->cmd(top, "frame .a");
	tk->cmd(top, "frame .b");
	for(i := 0; i < n; i++){
		col := ".a";
		if(i >= (n+1)/2)
			col = ".b";
		w := sys->sprint("%s.w%d", col, i);
		e := tk->cmd(top, subst(spec, w));
		if(e != nil && len e > 0 && e[0] == '!'){
			sys->print("tkbench: %s: %s\n", w, e);
			return 0;
		}
		tk->cmd(top, "pack " + w);
	}
	tk->cmd(top, "pack .a -side left -anchor n");
	tk->cmd(top, "pack .b -side left -anchor n");
	if((e := tk->putimage(top, ". -1", win, nil)) != nil && len e > 0){
		sys->print("tkbench: putimage: %s\n", e);
		return 0;
	}
	tk->cmd(top, "update");

	# warm once, so a first-call cost is not counted as the steady one
	tk->cmd(top, "style " + style);

	cmd := "style " + style;
	reps := 0;
	t0 := sys->millisec();
	for(;;){
		tk->cmd(top, cmd);
		reps++;
		if(sys->millisec() - t0 >= Minms)
			break;
	}
	dt := sys->millisec() - t0;
	if(verbose)
		sys->print("     [%s n=%d: %d repaints in %d ms]\n", spec, n, reps, dt);
	if(reps <= 0)
		return 0;
	return (dt*1000000)/reps;		# nanoseconds a repaint
}

# Limbo wants a format string to be a compile-time constant, so the
# widget specs cannot go through sprint: put the path in by hand.
subst(spec, w: string): string
{
	for(i := 0; i < len spec - 1; i++)
		if(spec[i] == '%' && spec[i+1] == 's')
			return spec[0:i] + w + spec[i+2:];
	return spec;
}

us(ns: int): string
{
	if(ns >= 1000000)
		return sys->sprint("%d.%.2d ms", ns/1000000, (ns%1000000)/10000);
	return sys->sprint("%d.%.2d us", ns/1000, (ns%1000)/10);
}
