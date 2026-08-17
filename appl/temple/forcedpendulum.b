implement Forcedpendulumapp;

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
include "danby/forcedpendulum.m";
	forcedpendulum: Forcedpendulum;
	Model: import forcedpendulum;
include "env.m";
	env: Env;

Forcedpendulumapp: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Pi: con 3.14159265358979323846;

win: ref Window;
font: ref Font;
background, foreground, grid, live, accent: ref Image;
graph: ref Plotter;
model: ref Model;
work: ref Numerics->Workspace;
state := array[] of {0.2,0.0};
time := 0.0;
paused := 0;
lastsection := -1;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	math = load Math Math->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	forcedpendulum = load Forcedpendulum Forcedpendulum->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || math == nil ||
			numerics == nil || plot == nil || forcedpendulum == nil)
		raise "fail:forcedpendulum: missing module";
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-forcedpendulum");
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,"Periodically forced pendulum",Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	background = win.display.color(int 16rf4f0e7ff);
	foreground = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	live = win.display.color(int 16r178f86ff);
	accent = win.display.color(int 16rb85c38ff);
	model = forcedpendulum->new(0.22,1.2,2.0/3.0);
	work = numerics->workspace(len state);
	graph = plot->new(win.image,font);
	declareplot();
	reset();
	win.reshape(Rect((0,0),(920,650)));
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
		"table history time angle velocity energy -capacity 8000\n" +
		"table section angle velocity -capacity 2000\n" +
		"colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour live 16r178f86ff\n" +
		"colour accent 16rb85c38ff");
	if(error != nil)
		raise "fail:forcedpendulum: " + error;
}

reset()
{
	state[0] = 0.2;
	state[1] = 0.0;
	time = 0.0;
	lastsection = -1;
	graph.cmd("history clear\nsection clear");
	record();
}

advance()
{
	h := 0.01;
	numerics->rk4(work,rhs,time,h,state);
	time += h;
	state[0] = wrap(state[0]);
	record();
	period := 2.0*Pi/model.frequency;
	section := int(time/period);
	if(section != lastsection){
		lastsection = section;
		graph.cmd(sys->sprint("section append %.17g %.17g",
			state[0],state[1]));
	}
}

rhs(t: real, values, derivative: array of real)
{
	model.rhs(t,values,derivative);
}

record()
{
	graph.cmd(sys->sprint(
		"history append %.17g %.17g %.17g %.17g",
		time,state[0],state[1],model.energy(state)));
}

wrap(angle: real): real
{
	while(angle > Pi)
		angle -= 2.0*Pi;
	while(angle < -Pi)
		angle += 2.0*Pi;
	return angle;
}

setpointer(point: Point)
{
	if(win.image == nil)
		return;
	r := win.image.r;
	if(point.y >= r.max.y-52){
		width := r.dx()/3;
		which := (point.x-r.min.x)/width;
		fraction := real(point.x-(r.min.x+which*width))/real(width);
		if(fraction < 0.01)
			fraction = 0.01;
		if(fraction > 0.99)
			fraction = 0.99;
		if(which == 0)
			model.damping = fraction;
		if(which == 1)
			model.drive = 2.0*fraction;
		if(which >= 2)
			model.frequency = 0.2+1.8*fraction;
	}else if(point.x < r.min.x+r.dx()/3){
		pivot := Point(r.min.x+r.dx()/6,r.min.y+105);
		dx := real(point.x-pivot.x);
		dy := real(point.y-pivot.y);
		state[0] = math->atan2(dx,dy);
		state[1] = 0.0;
		graph.cmd("history clear\nsection clear");
		time = 0.0;
		lastsection = -1;
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
	graph.cmd("clear");
	phase := Rect((image.r.min.x+image.r.dx()/3+42,image.r.min.y+38),
		(image.r.max.x-22,image.r.min.y+image.r.dy()/2-8));
	times := Rect((image.r.min.x+50,image.r.min.y+image.r.dy()/2+36),
		(image.r.max.x-22,image.r.max.y-65));
	tmin := time-30.0;
	if(tmin < 0.0)
		tmin = 0.0;
	tmax := tmin+30.0;
	graph.cmd(sys->sprint(
		"view phase %d %d %d %d\n" +
		"scale phase x -3.2 3.2\n" +
		"scale phase y -4 4 reverse\n" +
		"axis phase x angle grid\n" +
		"axis phase y angular-velocity grid\n" +
		"view time %d %d %d %d\n" +
		"scale time x %.9g %.9g\n" +
		"scale time y -3.2 3.2 reverse\n" +
		"axis time x time grid\n" +
		"axis time y angle grid",
		phase.min.x,phase.min.y,phase.max.x,phase.max.y,
		times.min.x,times.min.y,times.max.x,times.max.y,tmin,tmax));
	graph.cmd(
		"line phase history x angle y velocity colour live width 1\n" +
		"point phase section x angle y velocity colour accent radius 3\n" +
		"line time history x time y angle colour live width 2");
	graph.draw();
	drawpendulum(image);
	image.text(image.r.min.add((12,19)),foreground,Point(0,0),font,
		sys->sprint("theta''+%.3g theta'+sin(theta)=%.3g cos(%.3g t)   t %.2f",
			model.damping,model.drive,model.frequency,time));
	image.text((phase.min.x+5,phase.min.y+14),accent,Point(0,0),font,
		"orange: once per forcing period (Poincare section)");
	drawcontrols(image);
	image.flush(Draw->Flushnow);
}

drawpendulum(image: ref Image)
{
	pivot := Point(image.r.min.x+image.r.dx()/6,image.r.min.y+105);
	length := image.r.dy()/4;
	bob := Point(pivot.x+int(real(length)*math->sin(state[0])),
		pivot.y+int(real(length)*math->cos(state[0])));
	image.line((pivot.x-45,pivot.y),(pivot.x+45,pivot.y),0,0,3,grid,Point(0,0));
	image.line(pivot,bob,0,0,3,foreground,Point(0,0));
	image.ellipse(bob,13,13,0,live,Point(0,0));
	image.ellipse(pivot,5,5,0,accent,Point(0,0));
	image.text((pivot.x-75,pivot.y+length+28),foreground,Point(0,0),font,
		sys->sprint("angle %.3f   velocity %.3f",state[0],state[1]));
}

drawcontrols(image: ref Image)
{
	width := image.r.dx()/3;
	drawcontrol(image,0,"damping",model.damping,1.0,width);
	drawcontrol(image,1,"drive",model.drive,2.0,width);
	drawcontrol(image,2,"frequency",model.frequency,2.0,width);
}

drawcontrol(image: ref Image, which: int, name: string,
		value, maximum: real, width: int)
{
	left := image.r.min.x+which*width+8;
	right := left+width-16;
	y := image.r.max.y-28;
	image.line((left,y),(right,y),0,0,2,grid,Point(0,0));
	x := left+int(value/maximum*real(right-left));
	image.ellipse((x,y),4,4,0,accent,Point(0,0));
	image.text((left,image.r.max.y-9),foreground,Point(0,0),font,
		sys->sprint("%s %.3g",name,value));
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}
