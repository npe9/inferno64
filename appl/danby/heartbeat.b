implement Heartbeat;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;
include "danby/populationmodel.m";
	heartbeatmodel: Populationmodel;

Heartbeat: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, muscle, drive: ref Image;
model: ref Populationmodel->Model;
state := array[] of {-1.0,0.4};
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	heartbeatmodel = load Populationmodel "/dis/danby/plugin/heartbeat.dis";
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil ||
			plot == nil || heartbeatmodel == nil)
		raise "fail:Heartbeat: missing module";
	model = heartbeatmodel->new();
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-heartbeat");
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,"Zeeman heartbeat",Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	muscle = win.display.color(int 16rb85c38ff);
	drive = win.display.color(int 16r178f86ff);
	work = numerics->workspace(len state);
	graph = plot->new(win.image,font);
	graph.cmd("table history time muscle drive -capacity 16000");
	graph.cmd("colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour muscle 16rb85c38ff\n" +
		"colour drive 16r178f86ff");
	reset();
	win.reshape(Rect((0,0),(780,470)));
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
		handlepointer(pointer);
		redraw();
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		' ' => paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused) step();
		}
	<-ticks =>
		if(!paused)
			for(i := 0; i < 3; i++)
				step();
		redraw();
	}
}

rhs(rhsTime: real, values, derivative: array of real)
{
	heartbeatmodel->evaluate(model,rhsTime,values,derivative);
}

reset()
{
	state[0] = model.initial[0];
	state[1] = model.initial[1];
	t = 0.0;
	paused = 0;
	graph.cmd("history clear");
	record();
}

step()
{
	numerics->rk4(work,rhs,t,0.004,state);
	t += 0.004;
	record();
}

record()
{
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
		t,state[0],state[1]));
}

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	if(pointer.xy.y > r.max.y-55){
		width := r.dx()/3;
		which := (pointer.xy.x-r.min.x)/width;
		fraction := real(pointer.xy.x-(r.min.x+which*width))/real(width);
		if(which == 0){
			if(fraction < 0.02)
				fraction = 0.02;
			model.parameter[0] = 0.5*fraction;
		}
		if(which == 1)
			model.parameter[1] = 2.0*fraction;
		if(which >= 2)
			model.parameter[2] = 2.0*fraction-1.0;
		reset();
		return;
	}
	content := Rect(r.min.add((45,35)),r.max.sub((18,60)));
	middle := content.min.x+content.dx()/2;
	phase := Rect(content.min,(middle-24,content.max.y));
	if(pointer.xy.in(phase)){
		state[0] = -2.0+4.0*real(pointer.xy.x-phase.min.x)/real(phase.dx());
		state[1] = 2.0-4.0*real(pointer.xy.y-phase.min.y)/real(phase.dy());
		t = 0.0;
		graph.cmd("history clear");
		record();
	}
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 45 35 18 60\n" +
		"split content x phase 1 timeplot 1 gutter 54\n" +
		"view phase phase");
	graph.cmd("scale phase x -2 2");
	graph.cmd("scale phase y -2 2 reverse");
	graph.cmd("axis phase x muscle-state");
	graph.cmd("axis phase y drive");
	graph.cmd("line phase history x muscle y drive colour muscle width 2");
	tmax := t;
	if(tmax < 10.0)
		tmax = 10.0;
	graph.cmd("view timeplot timeplot");
	graph.cmd(sys->sprint("scale timeplot x 0 %.8g",tmax));
	graph.cmd("scale timeplot y -2 2 reverse");
	graph.cmd("axis timeplot x time");
	graph.cmd("axis timeplot y state");
	graph.cmd("line timeplot history x time y muscle colour muscle width 2");
	graph.cmd("line timeplot history x time y drive colour drive width 2");
	graph.draw();
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("Zeeman heartbeat   t %.2f   muscle %.3g   drive %.3g",
			t,state[0],state[1]));
	drawparameter(im,0,"fast time",model.parameter[0],0.5);
	drawparameter(im,1,"tension",model.parameter[1],2.0);
	drawparameter(im,2,"pacemaker",model.parameter[2]+1.0,2.0);
	im.flush(Draw->Flushnow);
}

drawparameter(im: ref Image, index: int, name: string,
		value, maximum: real)
{
	width := im.r.dx()/3;
	x := im.r.min.x+index*width;
	y := im.r.max.y-40;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	knob := x+4+int(value/maximum*real(width-10));
	im.ellipse((knob,y),4,4,0,fg,Point(0,0));
	im.text((x+4,im.r.max.y-17),fg,Point(0,0),font,
		sys->sprint("%s %.3g",name,value));
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}
