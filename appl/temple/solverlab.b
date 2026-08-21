implement Solverlab;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Rect, Point: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "math.m";
	math: Math;
include "numerics.m";
	numerics: Numerics;
	Tolerance: import numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;

Solverlab: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
graph: ref Plotter;
stem := "odesystems";
systemmode := 1;
fault := 0;
tolerancepower := -6;
accepted := 0;
rejected := 0;
maximumerror := 0.0;

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
		raise "fail:solverlab: missing support module";
	if(argv != nil)
		stem = hd argv;
	if(stem == "rkf45scalar")
		systemmode = 0;
	if(stem == "solverdebug")
		fault = 1;
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
	graph.cmd("table exact time first second -capacity 1200\n"+
		"table numerical time first second -capacity 1200\n"+
		"table error time first second -capacity 1200\n"+
		"colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour exact 16r20272cff\n"+
		"colour first 16rb85c38ff\n"+
		"colour second 16r178f86ff");
	recompute();
	win.reshape(Rect((0,0),(920,620)));
	win.onscreen("place");
	win.startinput("kbd"::nil);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		'1' => systemmode = 0; recompute(); redraw();
		'2' => systemmode = 1; recompute(); redraw();
		'f' or 'F' => fault = (fault+1)%4; recompute(); redraw();
		'+' or '=' => if(tolerancepower > -11) tolerancepower--; recompute(); redraw();
		'-' or '_' => if(tolerancepower < -2) tolerancepower++; recompute(); redraw();
		'r' or 'R' => fault = 0; tolerancepower = -6; recompute(); redraw();
		}
	}
}

title(): string
{
	case stem {
	"odesystems" => return "Systems of ordinary differential equations";
	"rkf45scalar" => return "RKF4(5): one equation";
	"rkf45system" => return "RKF4(5): a system";
	"solverdebug" => return "Debugging numerical solvers";
	"solverrun" => return "Running the solver";
	}
	return "Adaptive solver laboratory";
}

rhs(t: real, state, derivative: array of real)
{
	if(systemmode){
		derivative[0] = state[1];
		derivative[1] = -state[0];
		if(fault == 1)
			derivative[1] = state[0];
	}else{
		derivative[0] = state[0];
		if(fault == 1)
			derivative[0] = -state[0];
	}
	if(fault == 3)
		for(i := 0; i < len derivative; i++)
			derivative[i] += 0.08*t;
}

exact(t: real): array of real
{
	if(systemmode)
		return array[] of {math->cos(t),-math->sin(t)};
	return array[] of {math->exp(t)};
}

recompute()
{
	graph.cmd("exact clear\nnumerical clear\nerror clear");
	n := 1;
	if(systemmode)
		n = 2;
	state := array[n] of real;
	state[0] = 1.0;
	if(fault == 2)
		state[0] = 0.9;
	work := numerics->workspace(n);
	tolvalue := math->pow(10.0,real(tolerancepower));
	tolerance := Tolerance(tolvalue,tolvalue,1.0e-7,0.5);
	t := 0.0;
	h := 0.18;
	accepted = 0;
	rejected = 0;
	maximumerror = 0.0;
	record(t,state);
	while(t < 6.0){
		if(t+h > 6.0)
			h = 6.0-t;
		result := numerics->rkf45(work,rhs,tolerance,t,h,state);
		if(result.accepted){
			t = result.t;
			accepted++;
			record(t,state);
		}else
			rejected++;
		h = result.hnext;
		if(accepted+rejected > 20000)
			break;
	}
}

record(t: real, state: array of real)
{
	want := exact(t);
	firsterror := state[0]-want[0];
	seconderror := 0.0;
	second := 0.0;
	wantsecond := 0.0;
	if(len state > 1){
		second = state[1];
		wantsecond = want[1];
		seconderror = second-wantsecond;
	}
	graph.cmd(sys->sprint("exact append %.17g %.17g %.17g",t,want[0],wantsecond));
	graph.cmd(sys->sprint("numerical append %.17g %.17g %.17g",t,state[0],second));
	graph.cmd(sys->sprint("error append %.17g %.17g %.17g",t,firsterror,seconderror));
	magnitude := math->fabs(firsterror);
	if(math->fabs(seconderror) > magnitude)
		magnitude = math->fabs(seconderror);
	if(magnitude > maximumerror)
		maximumerror = magnitude;
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,im.display.color(int 16rf4f0e7ff),nil,Point(0,0));
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 45 55 25 55\nview solution content");
	graph.cmd("scale solution x 0 6\nscale solution y -3 3 reverse\n"+
		"axis solution x time\naxis solution y state\n"+
		"line solution exact x time y first colour exact width 1\n"+
		"line solution numerical x time y first colour first width 2");
	if(systemmode){
		graph.cmd("line solution exact x time y second colour exact width 1");
		graph.cmd("line solution numerical x time y second colour second width 2");
	}
	graph.draw();
	mode := "scalar";
	if(systemmode)
		mode = "system";
	im.text(im.r.min.add((12,20)),im.display.color(int 16r20272cff),Point(0,0),font,
		sys->sprint("%s   %s   tolerance 1e%d   accepted %d rejected %d   max error %.3g   fault %d",
			title(),mode,tolerancepower,accepted,rejected,maximumerror,fault));
	im.text((im.r.min.x+12,im.r.max.y-22),im.display.color(int 16r20272cff),Point(0,0),font,
		"1 scalar  2 system  F inject fault  +/- tolerance  R reset  Q quit");
	im.flush(Draw->Flushnow);
}
