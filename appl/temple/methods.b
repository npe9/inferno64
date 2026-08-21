implement Methods;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;
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

Methods: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Euler, Heun, Rk4: con iota;
Growth, Decay, Logistic: con iota;
Tend: con 4;

win: ref Window;
font: ref Font;
background, foreground, grid, exactcolour: ref Image;
eulercolour, heuncolour, rkcolour, adaptivecolour: ref Image;
graph: ref Plotter;
work: ref Numerics->Workspace;
stepsize := 0.4;
initial := 1.0;
equationmode := Growth;
adaptiveSteps := 0;
adaptiveRejects := 0;
showadaptive := 0;
lessonstem := "methods";

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
		raise "fail:methods: missing module";
	if(argv != nil)
		lessonstem = hd argv;
	if(lessonstem == "stepsize" || lessonstem == "rkf45")
		showadaptive = 1;
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-"+lessonstem);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,lessontitle(),Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	background = win.display.color(int 16rf4f0e7ff);
	foreground = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	exactcolour = win.display.color(int 16r20272cff);
	eulercolour = win.display.color(int 16rb85c38ff);
	heuncolour = win.display.color(int 16rd49a34ff);
	rkcolour = win.display.color(int 16r178f86ff);
	adaptivecolour = win.display.color(int 16r665191ff);
	work = numerics->workspace(1);
	graph = plot->new(win.image,font);
	declareplot();
	recompute();
	win.reshape(Rect((0,0),(920,680)));
	win.onscreen("place");
	win.startinput("kbd"::"ptr"::nil);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointer := <-win.ctxt.ptr =>
		win.pointer(*pointer);
		if(pointer.buttons&1){
			setpointer(pointer.xy);
			recompute();
			redraw();
		}
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' =>
			exit;
		'+' or '=' =>
			stepsize /= 1.4;
			boundstep();
			recompute();
			redraw();
		'-' or '_' =>
			stepsize *= 1.4;
			boundstep();
			recompute();
			redraw();
		'r' or 'R' =>
			stepsize = 0.4;
			setmode(equationmode);
			recompute();
			redraw();
		'1' =>
			setmode(Growth);
			recompute();
			redraw();
		'2' =>
			setmode(Decay);
			recompute();
			redraw();
		'3' =>
			setmode(Logistic);
			recompute();
			redraw();
		'd' or 'D' =>
			showadaptive = !showadaptive;
			redraw();
		}
	}
}

lessontitle(): string
{
	case lessonstem {
	"euler" => return "Euler's method";
	"truncation" => return "Truncation error";
	"methodorder" => return "Order of a numerical method";
	"eulerorder" => return "Confirming Euler's order";
	"heun" => return "Improved Euler's method";
	"rungekutta" => return "Runge-Kutta formulas";
	"stepsize" => return "Stepsize control";
	"rkf45" => return "Fehlberg RKF4(5)";
	}
	return "Numerical methods laboratory";
}

declareplot()
{
	error := graph.cmd(
		"table exact time value -capacity 256\n" +
		"table euler time value -capacity 1024\n" +
		"table eulerstep time value dt dy -capacity 1024\n" +
		"table heun time value -capacity 1024\n" +
		"table rk4 time value -capacity 1024\n" +
		"table adaptive time value -capacity 1024\n" +
		"table adaptiveinfo time logh logerror -capacity 1024\n" +
		"table rejected time logerror -capacity 1024\n" +
		"table field time value dt dy -capacity 256\n" +
		"table errors logh euler heun rk4 -capacity 16\n" +
		"colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour exact 16r20272cff\n" +
		"colour euler 16rb85c38ff\n" +
		"colour heun 16rd49a34ff\n" +
		"colour rk4 16r178f86ff\n" +
		"colour adaptive 16r665191ff");
	if(error != nil)
		raise "fail:methods: " + error;
}

equation(nil: real, state, derivative: array of real)
{
	case equationmode {
	Growth =>
		derivative[0] = state[0];
	Decay =>
		derivative[0] = -state[0];
	Logistic =>
		derivative[0] = 1.8*state[0]*(1.0-state[0]);
	}
}

recompute()
{
	graph.cmd("exact clear\n" +
		"euler clear\n" +
		"eulerstep clear\n" +
		"heun clear\n" +
		"rk4 clear\n" +
		"adaptive clear\n" +
		"adaptiveinfo clear\n" +
		"rejected clear\n" +
		"field clear\n" +
		"errors clear");
	for(i := 0; i <= 160; i++){
		t := real(i)*real(Tend)/160.0;
		graph.cmd(sys->sprint("exact append %.17g %.17g",
			t,exactvalue(t)));
	}
	fillfield();
	fillfixed("euler",Euler,stepsize);
	fillfixed("heun",Heun,stepsize);
	fillfixed("rk4",Rk4,stepsize);
	filladaptive();
	for(i = 0; i < 8; i++){
		h := 0.8/math->pow(2.0,real(i));
		exact := exactvalue(real(Tend));
		e1 := absreal(endpoint(Euler,h)-exact);
		e2 := absreal(endpoint(Heun,h)-exact);
		e4 := absreal(endpoint(Rk4,h)-exact);
		graph.cmd(sys->sprint(
			"errors append %.17g %.17g %.17g %.17g",
			math->log10(h),math->log10(e1),
			math->log10(e2),math->log10(e4)));
	}
}

fillfield()
{
	ymax := ymaximum();
	state := array[1] of real;
	derivative := array[1] of real;
	for(ix := 0; ix <= 12; ix++){
		t := real(ix)*real(Tend)/12.0;
		for(iy := 1; iy <= 9; iy++){
			state[0] = real(iy)*ymax/10.0;
			equation(t,state,derivative);
			dt := 0.12;
			dy := derivative[0]*dt;
			limit := ymax/14.0;
			if(dy > limit)
				dy = limit;
			if(dy < -limit)
				dy = -limit;
			graph.cmd(sys->sprint(
				"field append %.17g %.17g %.17g %.17g",
				t,state[0],dt,dy));
		}
	}
}

exactvalue(t: real): real
{
	case equationmode {
	Growth =>
		return initial*math->exp(t);
	Decay =>
		return initial*math->exp(-t);
	Logistic =>
		return 1.0/(1.0+(1.0/initial-1.0)*math->exp(-1.8*t));
	}
	return 0.0;
}

ymaximum(): real
{
	case equationmode {
	Growth =>
		return initial*math->exp(real(Tend))*1.08;
	Decay =>
		return initial*1.12;
	Logistic =>
		return 1.12;
	}
	return 1.0;
}

setmode(mode: int)
{
	equationmode = mode;
	case equationmode {
	Growth => initial = 1.0;
	Decay => initial = 1.0;
	Logistic => initial = 0.08;
	}
}

equationtitle(): string
{
	case equationmode {
	Growth => return "1: y' = y, exponential growth";
	Decay => return "2: y' = -y, exponential decay";
	Logistic => return "3: y' = 1.8y(1-y), nonlinear logistic growth";
	}
	return nil;
}

fillfixed(table: string, method: int, hmax: real)
{
	state := array[] of {initial};
	t := 0.0;
	graph.cmd(sys->sprint("%s append 0 %.17g",table,state[0]));
	while(t < real(Tend)){
		h := hmax;
		if(t+h > real(Tend))
			h = real(Tend)-t;
		if(method == Euler){
			derivative := array[1] of real;
			equation(t,state,derivative);
			graph.cmd(sys->sprint(
				"eulerstep append %.17g %.17g %.17g %.17g",
				t,state[0],h,h*derivative[0]));
		}
		step(method,t,h,state);
		t += h;
		graph.cmd(sys->sprint("%s append %.17g %.17g",
			table,t,state[0]));
	}
}

endpoint(method: int, hmax: real): real
{
	state := array[] of {initial};
	t := 0.0;
	while(t < real(Tend)){
		h := hmax;
		if(t+h > real(Tend))
			h = real(Tend)-t;
		step(method,t,h,state);
		t += h;
	}
	return state[0];
}

step(method: int, t, h: real, state: array of real)
{
	case method {
	Euler =>
		numerics->euler(work,equation,t,h,state);
	Heun =>
		numerics->heun(work,equation,t,h,state);
	Rk4 =>
		numerics->rk4(work,equation,t,h,state);
	}
}

filladaptive()
{
	state := array[] of {initial};
	tolerance := Tolerance(1.0e-7,1.0e-7,1.0e-6,0.8);
	t := 0.0;
	h := stepsize;
	adaptiveSteps = 0;
	adaptiveRejects = 0;
	graph.cmd(sys->sprint("adaptive append 0 %.17g",state[0]));
	while(t < real(Tend)){
		if(t+h > real(Tend))
			h = real(Tend)-t;
		result := numerics->rkf45(work,equation,tolerance,t,h,state);
		error := result.error;
		if(error < 1.0e-12)
			error = 1.0e-12;
		graph.cmd(sys->sprint(
			"adaptiveinfo append %.17g %.17g %.17g",
			t,math->log10(absreal(h)),math->log10(error)));
		if(result.accepted){
			t = result.t;
			adaptiveSteps++;
			graph.cmd(sys->sprint("adaptive append %.17g %.17g",
				t,state[0]));
		}else{
			adaptiveRejects++;
			graph.cmd(sys->sprint("rejected append %.17g %.17g",
				t,math->log10(error)));
		}
		h = result.hnext;
	}
}

setpointer(point: Point)
{
	if(win.image == nil)
		return;
	r := win.image.r;
	if(point.y >= r.max.y-54){
		fraction := real(point.x-r.min.x)/real(r.dx());
		if(fraction < 0.0)
			fraction = 0.0;
		if(fraction > 1.0)
			fraction = 1.0;
		stepsize = math->exp(math->log(0.005)+
			fraction*(math->log(0.8)-math->log(0.005)));
		boundstep();
	}
}

boundstep()
{
	if(stepsize < 0.005)
		stepsize = 0.005;
	if(stepsize > 0.8)
		stepsize = 0.8;
}

redraw()
{
	image := win.image;
	if(image == nil)
		return;
	image.draw(image.r,background,nil,Point(0,0));
	graph.image = image;
	graph.cmd("clear");
	middle := image.r.min.y+image.r.dy()*3/5;
	solution := Rect(image.r.min.add((52,42)),
		(image.r.max.x-22,middle-22));
	convergence := Rect((image.r.min.x+52,middle+24),
		(image.r.max.x-22,image.r.max.y-70));
	ymax := ymaximum();
	graph.cmd(sys->sprint(
		"rect solution %d %d %d %d\n" +
		"rect convergence %d %d %d %d\n" +
		"view solution solution",
		solution.min.x,solution.min.y,solution.max.x,solution.max.y,
		convergence.min.x,convergence.min.y,convergence.max.x,convergence.max.y));
	graph.cmd(sys->sprint(
		"scale solution x 0 %d\n" +
		"scale solution y 0 %.17g reverse\n" +
		"axis solution x time grid\n" +
		"axis solution y value grid",
		Tend,ymax));
	graph.cmd("vector solution field x time y value dx dt dy dy colour grid width 1\n" +
		"vector solution eulerstep x time y value dx dt dy dy colour euler width 1\n" +
		"line solution exact x time y value colour exact width 2\n" +
		"line solution euler x time y value colour euler width 1\n" +
		"line solution heun x time y value colour heun width 1\n" +
		"line solution rk4 x time y value colour rk4 width 2\n" +
		"point solution adaptive x time y value colour adaptive radius 2");
	graph.cmd("view convergence convergence");
	if(!showadaptive){
		graph.cmd(
			"scale convergence x -2.4 0\n" +
			"scale convergence y -13 2 reverse\n" +
			"axis convergence x log10(step) grid\n" +
			"axis convergence y log10(endpoint error) grid");
		graph.cmd("line convergence errors x logh y euler colour euler width 2\n" +
			"line convergence errors x logh y heun colour heun width 2\n" +
			"line convergence errors x logh y rk4 colour rk4 width 2");
	}else{
		graph.cmd(sys->sprint(
			"scale convergence x 0 %d\n" +
			"scale convergence y -12 1 reverse\n" +
			"axis convergence x trial-time grid\n" +
			"axis convergence y log10(step/error) grid",
			Tend));
		graph.cmd("line convergence adaptiveinfo x time y logh colour adaptive width 2\n" +
			"line convergence adaptiveinfo x time y logerror colour rk4 width 1\n" +
			"point convergence rejected x time y logerror colour euler radius 4");
	}
	graph.draw();
	image.text(image.r.min.add((12,20)),foreground,Point(0,0),font,
		equationtitle()+": analytic solution and direction field");
	image.text((solution.min.x+8,solution.min.y+15),exactcolour,
		Point(0,0),font,"exact");
	image.text((solution.min.x+58,solution.min.y+15),eulercolour,
		Point(0,0),font,"Euler");
	image.text((solution.min.x+112,solution.min.y+15),heuncolour,
		Point(0,0),font,"Heun");
	image.text((solution.min.x+160,solution.min.y+15),rkcolour,
		Point(0,0),font,"RK4");
	image.text((solution.min.x+198,solution.min.y+15),adaptivecolour,
		Point(0,0),font,"RKF45 accepted steps");
	image.text((image.r.min.x+12,image.r.max.y-45),foreground,
		Point(0,0),font,sys->sprint(
		"step %.5g   RKF45 accepted %d rejected %d   drag track or use +/-",
		stepsize,adaptiveSteps,adaptiveRejects));
	image.text((image.r.max.x-270,image.r.max.y-45),foreground,
		Point(0,0),font,"1 growth  2 decay  3 logistic   D diagnostics");
	drawtrack(image);
	image.flush(Draw->Flushnow);
}

drawtrack(image: ref Image)
{
	y := image.r.max.y-19;
	left := image.r.min.x+12;
	right := image.r.max.x-12;
	image.line((left,y),(right,y),0,0,2,grid,Point(0,0));
	fraction := (math->log(stepsize)-math->log(0.005))/
		(math->log(0.8)-math->log(0.005));
	x := left+int(fraction*real(right-left));
	image.ellipse((x,y),5,5,0,adaptivecolour,Point(0,0));
}

absreal(value: real): real
{
	if(value < 0.0)
		return -value;
	return value;
}
