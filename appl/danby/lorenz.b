implement Chaos;

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
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "paramtracks.m";
	paramtracks: Paramtracks;
	Tracks: import paramtracks;
include "danby/lorenz.m";
	lorenz: Lorenz;
	Model: import lorenz;
include "env.m";
	env: Env;

Chaos: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
background, foreground, live: ref Image;
graph: ref Plotter;
tracks: ref Tracks;
model: ref Model;
work, nearwork: ref Numerics->Workspace;
state := array[] of {0.1,0.0,0.0};
nearby := array[] of {0.100001,0.0,0.0};
time := 0.0;
paused := 0;
lessonstem := "chaos";
ControlBandH: con 74;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	math = load Math Math->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	paramtracks = load Paramtracks Paramtracks->PATH;
	lorenz = load Lorenz Lorenz->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || math == nil ||
			numerics == nil || plot == nil || paramtracks == nil || lorenz == nil)
		raise "fail:chaos: missing module";
	if(argv != nil && tl argv != nil)
		lessonstem = hd tl argv;
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-"+lessonstem);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	title := "Lorenz sensitive dependence";
	if(lessonstem == "chaosintro")
		title = "Introduction to chaos";
	if(lessonstem == "chaosdynamics")
		title = "Chaos in dynamical systems";
	win = wmclient->window(ctxt,title,Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	background = win.display.color(int 16rf4f0e7ff);
	foreground = win.display.color(int 16r20272cff);
	live = win.display.color(int 16r178f86ff);
	model = lorenz->new(10.0,28.0,8.0/3.0);
	work = numerics->workspace(len state);
	nearwork = numerics->workspace(len nearby);
	graph = plot->new(win.image,font);
	tracks = paramtracks->new(win.image,font);
	declareplot();
	declaretracks();
	reset();
	win.reshape(Rect((0,0),(900,610)));
	win.onscreen("place");
	win.startinput("kbd"::"ptr"::nil);
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointer := <-win.ctxt.ptr =>
		win.pointer(*pointer);
		if(pointer.buttons&1){
			setpointer(pointer.xy);
			redraw();
		}
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		' ' => paused = !paused;
		'.' =>
			if(paused){
				advance();
				redraw();
			}
		'r' or 'R' =>
			reset();
			redraw();
		}
	<-ticks =>
		if(!paused)
			for(i := 0; i < 5; i++)
				advance();
		redraw();
	}
}

declareplot()
{
	error := graph.cmd(
		"table trajectories time x z nearx nearz logdistance -capacity 10000\n" +
		"colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour live 16r178f86ff\n" +
		"colour accent 16rb85c38ff");
	if(error != nil)
		raise "fail:chaos: " + error;
}

declaretracks()
{
	error := tracks.cmd(
		"colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour accent 16rb85c38ff\n" +
		"band " + string ControlBandH + "\n" +
		"track sigma 0 25 colour accent\n" +
		"track rho 0 50 colour accent\n" +
		"track beta 0 5 colour accent\n" +
		"set sigma 10\n" +
		"set rho 28\n" +
		sys->sprint("set beta %g", 8.0/3.0));
	if(error != nil)
		raise "fail:chaos: " + error;
}

reset()
{
	state[0] = 0.1;
	state[1] = 0.0;
	state[2] = 0.0;
	nearby[0] = state[0]+1.0e-6;
	nearby[1] = state[1];
	nearby[2] = state[2];
	time = 0.0;
	graph.cmd("trajectories clear");
	record();
}

rhs(t: real, values, derivative: array of real)
{
	model.rhs(t,values,derivative);
}

advance()
{
	h := 0.0025;
	numerics->rk4(work,rhs,time,h,state);
	numerics->rk4(nearwork,rhs,time,h,nearby);
	time += h;
	record();
}

record()
{
	dx := nearby[0]-state[0];
	dy := nearby[1]-state[1];
	dz := nearby[2]-state[2];
	distance := math->sqrt(dx*dx+dy*dy+dz*dz);
	if(distance < 1.0e-15)
		distance = 1.0e-15;
	graph.cmd(sys->sprint(
		"trajectories append %.17g %.17g %.17g %.17g %.17g %.17g",
		time,state[0],state[2],nearby[0],nearby[2],math->log10(distance)));
}

setpointer(point: Point)
{
	if(win.image == nil)
		return;
	r := win.image.r;
	bandtop := r.max.y-ControlBandH;
	(name, value, ok) := tracks.hit(point, r);
	if(ok){
		case name {
		"sigma" => model.sigma = value;
		"rho" => model.rho = value;
		"beta" => model.beta = value;
		}
		reset();
	}else{
		drawh := bandtop-r.min.y-40;
		if(drawh < 20)
			drawh = 20;
		relative := real((bandtop-8)-point.y)/real(drawh);
		state[0] = 30.0*(relative-0.5);
		nearby[0] = state[0]+1.0e-6;
		nearby[1] = state[1];
		nearby[2] = state[2];
		time = 0.0;
		graph.cmd("trajectories clear");
		record();
	}
}

redraw()
{
	image := win.image;
	if(image == nil)
		return;
	image.draw(image.r,background,nil,Point(0,0));
	graph.image = image;
	tracks.image = image;
	graph.cmd("clear");
	bandtop := image.r.max.y-ControlBandH;
	middle := image.r.min.y+image.r.dy()*2/3;
	phase := Rect(image.r.min.add((50,38)),
		(image.r.max.x-22,middle-20));
	separation := Rect((image.r.min.x+50,middle+22),
		(image.r.max.x-22,bandtop-10));
	tmin := time-25.0;
	if(tmin < 0.0)
		tmin = 0.0;
	tmax := tmin+25.0;
	graph.cmd(sys->sprint(
		"view phase %d %d %d %d\n" +
		"scale phase x -22 22\n" +
		"scale phase y 0 52 reverse\n" +
		"axis phase x x grid\n" +
		"axis phase y z grid\n" +
		"view separation %d %d %d %d\n" +
		"scale separation x %.9g %.9g\n" +
		"scale separation y -7 2 reverse\n" +
		"axis separation x time grid\n" +
		"axis separation y log10-distance grid",
		phase.min.x,phase.min.y,phase.max.x,phase.max.y,
		separation.min.x,separation.min.y,separation.max.x,separation.max.y,
		tmin,tmax));
	graph.cmd(
		"line phase trajectories x x y z colour live width 2\n" +
		"line phase trajectories x nearx y nearz colour accent width 1\n" +
		"line separation trajectories x time y logdistance colour accent width 2");
	graph.draw();
	image.text(image.r.min.add((12,19)),foreground,Point(0,0),font,
		sys->sprint("Lorenz pair: initial separation 10^-6   t %.2f   x %.3f/%.3f",
			time,state[0],nearby[0]));
	tracks.draw(image.r);
	image.flush(Draw->Flushnow);
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}
