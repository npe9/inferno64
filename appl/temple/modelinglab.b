implement Modelinglab;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "danby/stability.m";
	stability: Stability;
	Model: import stability;
include "env.m";
	env: Env;

Modelinglab: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
background, foreground, grid, live, accent: ref Image;
graph: ref Plotter;
model: ref Model;
work, linearwork: ref Numerics->Workspace;
state := array[] of {1.6,0.25};
linearstate := array[] of {1.6,0.25};
time := 0.0;
paused := 0;
stem := "modeling";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	stability = load Stability Stability->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil ||
			plot == nil || stability == nil)
		raise "fail:modelinglab: missing module";
	if(argv != nil && tl argv != nil)
		stem = hd tl argv;
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-"+stem);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,"Model assumptions and stability",Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	background = win.display.color(int 16rf4f0e7ff);
	foreground = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	live = win.display.color(int 16r178f86ff);
	accent = win.display.color(int 16rb85c38ff);
	model = stability->new(0.18);
	work = numerics->workspace(2);
	linearwork = numerics->workspace(2);
	graph = plot->new(win.image,font);
	graph.cmd("table paths time x y lx ly -capacity 10000\n"+
		"colour foreground 16r20272cff\ncolour grid 16rd6d0c4ff\n"+
		"colour live 16r178f86ff\ncolour accent 16rb85c38ff");
	reset();
	win.reshape(Rect((0,0),(980,690)));
	win.onscreen("exact");
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
			setgrowth(pointer.xy);
			redraw();
		}
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => exit;
		' ' => paused = !paused;
		'r' or 'R' => reset();
		}
	<-ticks =>
		if(!paused)
			for(i := 0; i < 4; i++)
				advance();
		redraw();
	}
}

reset()
{
	state[0] = 1.6;
	state[1] = 0.25;
	linearstate[0] = state[0];
	linearstate[1] = state[1];
	time = 0.0;
	graph.cmd("paths clear");
	record();
}

rhs(t: real, values, derivative: array of real)
{
	model.rhs(t,values,derivative);
}

linearrhs(t: real, values, derivative: array of real)
{
	model.linear(t,values,derivative);
}

advance()
{
	h := 0.01;
	numerics->rk4(work,rhs,time,h,state);
	numerics->rk4(linearwork,linearrhs,time,h,linearstate);
	time += h;
	record();
}

record()
{
	graph.cmd(sys->sprint("paths append %.9g %.9g %.9g %.9g %.9g",
		time,state[0],state[1],linearstate[0],linearstate[1]));
}

setgrowth(point: Point)
{
	if(win.image == nil || point.y < win.image.r.max.y-54)
		return;
	fraction := real(point.x-win.image.r.min.x)/real(win.image.r.dx());
	if(fraction < 0.02)
		fraction = 0.02;
	if(fraction > 0.98)
		fraction = 0.98;
	model.growth = -0.5+fraction;
	reset();
}

redraw()
{
	image := win.image;
	if(image == nil)
		return;
	image.draw(image.r,background,nil,Point(0,0));
	graph.image = image;
	graph.cmd("clear");
	middle := image.r.min.x+image.r.dx()/2;
	phase := Rect(image.r.min.add((50,50)),(middle-18,image.r.max.y-75));
	series := Rect((middle+45,image.r.min.y+50),(image.r.max.x-22,image.r.max.y-75));
	tmax := time;
	if(tmax < 10.0)
		tmax = 10.0;
	graph.cmd(sys->sprint(
		"view phase %d %d %d %d\nscale phase x -3 3\nscale phase y -3 3 reverse\naxis phase x x grid\naxis phase y y grid\n"+
		"view series %d %d %d %d\nscale series x 0 %.9g\nscale series y -5 5 reverse\naxis series x time grid\naxis series y x grid",
		phase.min.x,phase.min.y,phase.max.x,phase.max.y,
		series.min.x,series.min.y,series.max.x,series.max.y,tmax));
	graph.cmd("line phase paths x x y y colour live width 2\n"+
		"line phase paths x lx y ly colour accent width 1\n"+
		"line series paths x time y x colour live width 2\n"+
		"line series paths x time y lx colour accent width 1");
	graph.draw();
	classification := "stable focus";
	if(model.growth == 0.0)
		classification = "neutral linearization / nonlinear stable";
	if(model.growth > 0.0)
		classification = "unstable equilibrium / stable limit cycle";
	image.text(image.r.min.add((14,20)),foreground,Point(0,0),font,
		sys->sprint("green nonlinear; ochre linearization   a %.3f: %s",
			model.growth,classification));
	y := image.r.max.y-30;
	image.line((image.r.min.x+12,y),(image.r.max.x-12,y),0,0,2,grid,Point(0,0));
	x := image.r.min.x+int((model.growth+0.5)*real(image.r.dx()));
	image.ellipse((x,y),5,5,0,accent,Point(0,0));
	image.text((image.r.min.x+12,image.r.max.y-10),foreground,Point(0,0),font,
		"click scale: a -0.5 .. +0.5    space pause    r reset");
	image.flush(Draw->Flushnow);
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}
