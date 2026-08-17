implement Trajectoryclient;

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
include "danby/trajectory.m";

Trajectoryclient: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, pathcolour, speedcolour: ref Image;
modelmodule: Trajectory;
model: ref Trajectory->Model;
labels: array of string;
ranges: array of real;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
finished := 0;
groundimpact := 0;
xmaximum := 10.0;
ymaximum := 5.0;
speedmaximum := 10.0;
ControlBandH: con 76;

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
		raise "fail:Trajectory: missing support module";
	if(tl argv == nil){
		sys->print("usage: trajectory model.dis [manual]\n");
		return;
	}
	modelpath := hd tl argv;
	modelmodule = load Trajectory modelpath;
	if(modelmodule == nil)
		raise "fail:Trajectory: cannot load " + modelpath;
	model = modelmodule->new();
	labels = modelmodule->parameterlabels();
	ranges = modelmodule->parameterranges();
	if(len labels != len model.parameter || len ranges != len model.parameter)
		raise "fail:Trajectory: parameter metadata count";
	if(env != nil){
		env->clone();
		manual := "danby-"+hd argv;
		if(tl tl argv != nil)
			manual = hd tl tl argv;
		env->setenv("wmman",manual);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,modelmodule->title(),Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	pathcolour = win.display.color(int 16rb85c38ff);
	speedcolour = win.display.color(int 16r178f86ff);
	graph = plot->new(win.image,font);
	graph.cmd("table history time x y speed -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour path 16rb85c38ff\n" +
		"colour speed 16r178f86ff");
	reset();
	win.reshape(Rect((0,0),(820,500)));
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
		handlepointer(pointer);
		redraw();
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		' ' => if(!finished) paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused && !finished) step();
		}
	<-ticks =>
		if(!paused && !finished)
			for(i := 0; i < 5 && !finished; i++)
				step();
		redraw();
	}
}

rhs(rhsTime: real, values, derivative: array of real)
{
	modelmodule->evaluate(model,rhsTime,values,derivative);
}

reset()
{
	state = modelmodule->initialstate(model);
	if(len state != 4)
		raise "fail:Trajectory: expected x y vx vy state";
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	groundimpact = 0;
	xmaximum = 10.0;
	ymaximum = 5.0;
	speedmaximum = speed();
	if(speedmaximum < 10.0)
		speedmaximum = 10.0;
	graph.cmd("history clear");
	record();
}

step()
{
	h := 0.005;
	old := array[] of {state[0],state[1],state[2],state[3]};
	oldt := t;
	numerics->rk4(work,rhs,t,h,state);
	t += h;
	if(state[1] < 0.0 && old[1] >= 0.0 && oldt > 0.0){
		fraction := old[1]/(old[1]-state[1]);
		for(i := 0; i < len state; i++)
			state[i] = old[i]+fraction*(state[i]-old[i]);
		state[1] = 0.0;
		t = oldt+fraction*h;
		finished = 1;
		groundimpact = 1;
		paused = 1;
	}
	if(t >= modelmodule->maxtime(model)){
		finished = 1;
		paused = 1;
	}
	if(state[0]*1.1 > xmaximum)
		xmaximum = state[0]*1.1;
	if(state[1]*1.15 > ymaximum)
		ymaximum = state[1]*1.15;
	if(speed()*1.1 > speedmaximum)
		speedmaximum = speed()*1.1;
	record();
}

speed(): real
{
	return math->sqrt(state[2]*state[2]+state[3]*state[3]);
}

record()
{
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g",
		t,state[0],state[1],speed()));
}

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	bandtop := r.max.y-ControlBandH;
	if(pointer.xy.y < bandtop)
		return;
	n := len model.parameter;
	width := r.dx()/n;
	which := (pointer.xy.x-r.min.x)/width;
	if(which < 0)
		which = 0;
	if(which >= n)
		which = n-1;
	fraction := real(pointer.xy.x-(r.min.x+which*width))/real(width);
	if(fraction < 0.01)
		fraction = 0.01;
	model.parameter[which] = ranges[which]*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	bandtop := im.r.max.y-ControlBandH;
	content := Rect(im.r.min.add((48,38)),(im.r.max.x-18,bandtop-10));
	middle := content.min.x+(content.dx()*2)/3;
	flight := Rect(content.min,(middle-25,content.max.y));
	telemetry := Rect((middle+30,content.min.y),content.max);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view flight %d %d %d %d",
		flight.min.x,flight.min.y,flight.max.x,flight.max.y));
	graph.cmd(sys->sprint("scale flight x 0 %.8g",xmaximum));
	graph.cmd(sys->sprint("scale flight y 0 %.8g reverse",ymaximum));
	graph.cmd("axis flight x distance");
	graph.cmd("axis flight y height");
	graph.cmd("line flight history x x y y colour path width 2");
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	graph.cmd(sys->sprint("view telemetry %d %d %d %d",
		telemetry.min.x,telemetry.min.y,telemetry.max.x,telemetry.max.y));
	graph.cmd(sys->sprint("scale telemetry x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale telemetry y 0 %.8g reverse",speedmaximum));
	graph.cmd("axis telemetry x time");
	graph.cmd("axis telemetry y speed");
	graph.cmd("line telemetry history x time y speed colour speed width 2");
	graph.draw();
	status := "in flight";
	if(groundimpact)
		status = "landed";
	else if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   %s   t %.3g   range %.3g   speed %.3g",
			modelmodule->title(),status,t,state[0],speed()));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im,i,labels[i],model.parameter[i],ranges[i]);
	im.flush(Draw->Flushnow);
}

drawparameter(im: ref Image, index: int, name: string,
		value, maximum: real)
{
	width := im.r.dx()/len model.parameter;
	x := im.r.min.x+index*width;
	bandtop := im.r.max.y-ControlBandH;
	y := bandtop+24;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	knob := x+4+int(value/maximum*real(width-10));
	im.ellipse((knob,y),4,4,0,fg,Point(0,0));
	maxchars := (width-10)/8;
	if(maxchars < 6)
		maxchars = 6;
	im.text((x+4,bandtop+47),fg,Point(0,0),font,
		sys->sprint("%s %.3g",fitlabel(name,maxchars),value));
}

fitlabel(name: string, maxchars: int): string
{
	if(name == nil)
		return "";
	if(maxchars < 4)
		maxchars = 4;
	if(len name <= maxchars)
		return name;
	return name[0:maxchars-3]+"...";
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}
