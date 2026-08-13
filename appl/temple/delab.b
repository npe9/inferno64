implement Delab;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "math.m";
	math: Math;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;

Delab: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

win: ref Window;
font: ref Font;
graph: ref Plotter;
stem := "meaning";
mode := 0;
initial := 0.35;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	math = load Math Math->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || math == nil ||
			numerics == nil || plot == nil)
		raise "fail:delab: missing support module";
	if(argv != nil)
		stem = hd argv;
	case stem {
	"meaning" => mode = 0;
	"instructions" => mode = 1;
	"solutions" => mode = 2;
	"existence" => mode = 3;
	"chapter1assignments" => mode = 4;
	}
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-"+stem);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,title(),Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	graph = plot->new(win.image,font);
	graph.cmd("table field time value dt dy -capacity 800\n"+
		"table solution time value -capacity 1000\n"+
		"table alternate time value -capacity 1000\n"+
		"colour foreground 16r20272cff\ncolour grid 16rd6d0c4ff\n"+
		"colour first 16rb85c38ff\ncolour second 16r178f86ff");
	recompute();
	win.reshape(Rect((0,0),(900,610)));
	win.onscreen("exact");
	win.startinput("kbd"::"ptr"::nil);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl => win.wmctl(ctl); redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		if(p.buttons&1){
			initial = -1.8+3.6*real(p.xy.y-win.image.r.min.y)/real(win.image.r.dy());
			recompute();
			redraw();
		}
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' => exit;
		'1' => mode = 0; recompute(); redraw();
		'2' => mode = 1; recompute(); redraw();
		'3' => mode = 2; recompute(); redraw();
		'4' => mode = 3; recompute(); redraw();
		'5' => mode = 4; recompute(); redraw();
		}
	}
}

title(): string
{
	case stem {
	"meaning" => return "What a differential equation means";
	"instructions" => return "What a differential equation tells us to do";
	"solutions" => return "Interpreting a solution";
	"existence" => return "Existence and uniqueness";
	"chapter1assignments" => return "Differential-equation assignments";
	}
	return "Differential equation laboratory";
}

rhs(t: real, state, derivative: array of real)
{
	case mode {
	0 => derivative[0] = state[0]-0.45*t;
	1 => derivative[0] = t-state[0];
	2 => derivative[0] = state[0]*(1.0-state[0]);
	3 =>
		if(state[0] >= 0.0)
			derivative[0] = math->sqrt(state[0]);
		else
			derivative[0] = -math->sqrt(-state[0]);
	4 => derivative[0] = math->sin(t)-0.35*state[0];
	}
}

recompute()
{
	graph.cmd("field clear\nsolution clear\nalternate clear");
	state := array[1] of real;
	derivative := array[1] of real;
	for(ix := 0; ix <= 16; ix++){
		t := 4.0*real(ix)/16.0;
		for(iy := 0; iy <= 12; iy++){
			y := -2.0+4.0*real(iy)/12.0;
			state[0] = y;
			rhs(t,state,derivative);
			dy := 0.14*derivative[0];
			if(dy > 0.25) dy = 0.25;
			if(dy < -0.25) dy = -0.25;
			graph.cmd(sys->sprint("field append %.17g %.17g .14 %.17g",t,y,dy));
		}
	}
	state[0] = initial;
	w := numerics->workspace(1);
	t := 0.0;
	graph.cmd(sys->sprint("solution append 0 %.17g",state[0]));
	while(t < 4.0){
		h := 0.01;
		numerics->rk4(w,rhs,t,h,state);
		t += h;
		graph.cmd(sys->sprint("solution append %.17g %.17g",t,state[0]));
	}
	if(mode == 3){
		for(i := 0; i <= 300; i++){
			t = 4.0*real(i)/300.0;
			y := 0.0;
			if(t > 1.0)
				y = (t-1.0)*(t-1.0)/4.0;
			graph.cmd(sys->sprint("alternate append %.17g %.17g",t,y));
		}
	}
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	bg := im.display.color(int 16rf4f0e7ff);
	fg := im.display.color(int 16r20272cff);
	im.draw(im.r,bg,nil,Point(0,0));
	graph.image = im;
	graph.cmd("clear");
	r := Rect(im.r.min.add((55,55)),im.r.max.sub((30,55)));
	graph.cmd(sys->sprint("view fieldview %d %d %d %d",r.min.x,r.min.y,r.max.x,r.max.y));
	graph.cmd("scale fieldview x 0 4\nscale fieldview y -2 2 reverse\n"+
		"axis fieldview x independent variable\naxis fieldview y dependent variable\n"+
		"vectors fieldview field x time y value dx dt dy dy colour grid width 1\n"+
		"line fieldview solution x time y value colour first width 3\n"+
		"line fieldview alternate x time y value colour second width 2");
	graph.draw();
	im.text(im.r.min.add((12,20)),fg,Point(0,0),font,
		sys->sprint("%s   initial value %.3g",title(),initial));
	im.text((im.r.min.x+12,im.r.max.y-22),fg,Point(0,0),font,
		"click vertically to change initial value   1-5 lesson modes   Q quit");
	im.flush(Draw->Flushnow);
}
