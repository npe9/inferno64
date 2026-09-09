implement Cartesian;

# TempleOS Demo/Graphics/Cartesian.HC — ask the user for y=f(x), graph it.
#
# Original structure (Demo_Graphics_Cartesian.HC): loop {
#   DocClear; print "Enter algebraic equation to graph." / "Example: y=2*x"
#   / "y="; GetStr.  Empty string or no string -> exit.  Otherwise draw a
#   full-window RED cross of axes through the centre, then for x = -h..h
#   in PIXELS evaluate y = -ExePrint("ToF64(%s);",st) (x, y, y_last are
#   globals the expression can read) and GrLine the previous sample to the
#   current one in BLACK, y negated so positive is up.  GetChar; DCFill;
#   repeat until Esc/Shift-Esc.
# }
# The prompt text stays on screen while the graph is drawn over it, so we
# repaint prompt + axes + curve together.
#
# The expression is evaluated with hoc(2) (appl/lib/hoc.b): reset(), then
# setvar x/y/y_last, compile() once per equation, setvar("x",..)+eval()
# per pixel — the same parse-once/eval-many pattern pde(2)'s `equation
# hoc` uses.
#
# GAP: the original JIT-compiles the entered text as arbitrary HolyC
# (ExePrint), so any HolyC expression — function calls, casts — is legal.
# Here the grammar is hoc(2)'s expression language (sin, cos, tan, atan,
# log, exp, sqrt, abs, int, ^, PI, ...; globals x, y, y_last), which
# covers every algebraic equation the demo is about but is not HolyC.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "hoc.m";
	hoc: Hoc;
include "grpalette.m";
	grpal: Grpalette;

Cartesian: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# TempleOS palette entries used here

win: ref Window;
red, white, black: ref Image;
font: ref Font;

# GetStr/GetChar state machine
MENTRY, MGRAPH: con iota;	# typing the equation / graph shown, waiting for a key
mode := MENTRY;
input := "";			# text after the "y=" prompt
expr: ref Hoc->Expr;		# compiled equation (nil after a compile error)
errmsg := "";			# shown in MGRAPH when expr is nil

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	hoc = load Hoc Hoc->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Cartesian", Wmclient->Appl);
	d := win.display;
	red = d.color(grpal->value(Grpalette->RED));
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");
	win.reshape(Rect((0, 0), (640, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	render();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			render();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	}
}

key(k: int)
{
	if(k == 16r1b)		# Esc: GetStr aborted / GetChar Esc — exit
		exit;
	case mode {
	MENTRY =>
		if(k == '\n' || k == '\r'){
			if(input == "")
				exit;	# empty equation: original exits
			submit();
			return;
		}
		if(k == '\b' || k == 16r7f){
			if(input != "")
				input = input[:len input - 1];
		}else if(k >= ' ' && k < 16rE000)
			input += sys->sprint("%c", k);
		render();
	MGRAPH =>
		# GetChar after the graph: any key clears and re-prompts
		input = "";
		expr = nil;
		errmsg = "";
		mode = MENTRY;
		render();
	}
}

submit()
{
	expr = nil;
	errmsg = "";
	if(hoc == nil){
		errmsg = "cannot load " + Hoc->PATH;
	}else{
		hoc->reset();
		# the original's globals, readable by the expression
		hoc->setvar("x", 0.0);
		hoc->setvar("y", 0.0);
		hoc->setvar("y_last", 0.0);
		expr = hoc->compile(input);
		if(expr == nil)
			errmsg = "hoc could not compile: " + input;
	}
	mode = MGRAPH;
	render();
}

render()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));	# DocClear/DCFill: white doc
	o := img.r.min;
	# the doc prompt, 8x8 cells from the top-left, black on white
	line0 := "Enter algebraic equation to graph.";
	line1 := "Example: y=2*x";
	line2 := "y=" + input;
	if(font != nil){
		img.text(Point(o.x, o.y), black, Point(0, 0), font, line0);
		img.text(Point(o.x, o.y+8), black, Point(0, 0), font, line1);
		img.text(Point(o.x, o.y+16), black, Point(0, 0), font, line2);
		if(mode == MENTRY){
			# block cursor after the typed text
			cx := o.x + font.width(line2);
			img.draw(Rect((cx, o.y+16), (cx+8, o.y+24)), black, nil, Point(0, 0));
		}
	}
	if(mode == MGRAPH)
		graph(img);
	img.flush(Draw->Flushnow);
}

# The graph proper, in the original's 1:1 pixel space: x runs -h..h in
# pixels, the expression's value is y in pixels, negated so positive is
# up; samples are joined by line segments.  No auto-scaling — "y=2*x" is
# a line of slope 2 in pixels, exactly as in TempleOS.
graph(img: ref Image)
{
	if(expr == nil){
		if(font != nil && errmsg != "")
			img.text(Point(img.r.min.x, img.r.min.y+32), red, Point(0, 0), font, errmsg);
		return;
	}
	w := img.r.dx();
	ht := img.r.dy();
	h := w/2;
	v := ht/2;
	cx := img.r.min.x + h;
	cy := img.r.min.y + v;
	# RED axes, a full-window cross through the centre
	img.line(Point(cx, img.r.min.y), Point(cx, img.r.max.y), 0, 0, 0, red, Point(0, 0));
	img.line(Point(img.r.min.x, cy), Point(img.r.max.x, cy), 0, 0, 0, red, Point(0, 0));
	xsym := hoc->symbol("x");
	ysym := hoc->symbol("y");
	lsym := hoc->symbol("y_last");
	ylast := 0.0;
	first := 1;
	for(x := -h; x <= h; x++){
		xsym.val = real x;
		y := -hoc->eval(expr);
		if(!first)
			img.line(Point(cx+x-1, cy+int ylast), Point(cx+x, cy+int y),
				0, 0, 0, black, Point(0, 0));
		ylast = y;
		ysym.val = y;	# next sample's expression sees this sample's y
		lsym.val = y;
		first = 0;
	}
}
