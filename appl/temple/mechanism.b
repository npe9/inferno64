implement Mechanismclient;

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
include "danby/mechanism.m";

Mechanismclient: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, bodycolour, firstcolour, secondcolour: ref Image;
modelmodule: Mechanism;
model: ref Mechanism->Model;
labels: array of string;
minima, maxima: array of real;
observablelabels: array of string;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
finished := 0;
observationmaximum := array[] of {1.0,1.0};
ControlBandH: con 76;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil ||
			plot == nil)
		raise "fail:Mechanism: missing support module";
	if(tl argv == nil){
		sys->print("usage: mechanism model.dis [manual]\n");
		return;
	}
	modelpath := hd tl argv;
	modelmodule = load Mechanism modelpath;
	if(modelmodule == nil)
		raise "fail:Mechanism: cannot load "+modelpath;
	model = modelmodule->new();
	labels = modelmodule->parameterlabels();
	minima = modelmodule->parameterminima();
	maxima = modelmodule->parametermaxima();
	observablelabels = modelmodule->observablelabels();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len maxima != len model.parameter)
		raise "fail:Mechanism: parameter metadata count";
	if(len observablelabels != 2)
		raise "fail:Mechanism: expected two observables";
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
	bodycolour = win.display.color(int 16rb85c38ff);
	firstcolour = win.display.color(int 16r178f86ff);
	secondcolour = win.display.color(int 16r7b5aa6ff);
	graph = plot->new(win.image,font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour first 16r178f86ff\n"+
		"colour second 16r7b5aa6ff");
	reset();
	win.reshape(Rect((0,0),(900,560)));
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
		16r1b or 'q' or 'Q' => exit;
		' ' => if(!finished) paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused && !finished) step();
		}
	<-ticks =>
		if(!paused && !finished)
			for(i := 0; i < 4 && !finished; i++)
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
	if(len state == 0)
		raise "fail:Mechanism: empty state";
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	observationmaximum[0] = 1.0;
	observationmaximum[1] = 1.0;
	graph.cmd("history clear");
	record();
}

step()
{
	h := 0.005;
	numerics->rk4(work,rhs,t,h,state);
	t += h;
	if(t >= modelmodule->maxtime(model)){
		finished = 1;
		paused = 1;
	}
	record();
}

record()
{
	values := modelmodule->observables(model,state);
	if(len values != 2)
		raise "fail:Mechanism: observable count changed";
	for(i := 0; i < 2; i++){
		magnitude := values[i];
		if(magnitude < 0.0)
			magnitude = -magnitude;
		if(magnitude*1.15 > observationmaximum[i])
			observationmaximum[i] = magnitude*1.15;
	}
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
		t,values[0],values[1]));
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
	model.parameter[which] = minima[which]+
		(maxima[which]-minima[which])*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	bandtop := im.r.max.y-ControlBandH;
	content := Rect(im.r.min.add((25,38)),(im.r.max.x-18,bandtop-10));
	middle := content.min.x+(content.dx()*3)/5;
	mechanismview := Rect(content.min,(middle-20,content.max.y));
	plotview := Rect((middle+35,content.min.y),content.max);
	drawmechanism(im,mechanismview);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view quantities %d %d %d %d",
		plotview.min.x,plotview.min.y,plotview.max.x,plotview.max.y));
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	ymax := observationmaximum[0];
	if(observationmaximum[1] > ymax)
		ymax = observationmaximum[1];
	graph.cmd(sys->sprint("scale quantities x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale quantities y %.8g %.8g reverse",-ymax,ymax));
	graph.cmd("axis quantities x time");
	graph.cmd("axis quantities y value");
	graph.cmd("line quantities history x time y first colour first width 2");
	graph.cmd("line quantities history x time y second colour second width 2");
	graph.draw();
	values := modelmodule->observables(model,state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   %s   t %.3g   %s %.3g   %s %.3g",
			modelmodule->title(),status,t,observablelabels[0],values[0],
			observablelabels[1],values[1]));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im,i,labels[i],model.parameter[i],maxima[i]);
	im.flush(Draw->Flushnow);
}

drawmechanism(im: ref Image, view: Rect)
{
	points := modelmodule->geometry(model,state);
	links := modelmodule->links();
	if(len points == 0 || len points%2 != 0 || len links%2 != 0)
		return;
	xmin := points[0];
	xmax := points[0];
	ymin := points[1];
	ymax := points[1];
	for(i := 0; i < len points/2; i++){
		x := points[2*i];
		y := points[2*i+1];
		if(x < xmin)
			xmin = x;
		if(x > xmax)
			xmax = x;
		if(y < ymin)
			ymin = y;
		if(y > ymax)
			ymax = y;
	}
	if(xmax-xmin < 1.0){
		xmin -= 0.5;
		xmax += 0.5;
	}
	if(ymax-ymin < 1.0){
		ymin -= 0.5;
		ymax += 0.5;
	}
	xpad := (xmax-xmin)*0.15;
	ypad := (ymax-ymin)*0.15;
	xmin -= xpad;
	xmax += xpad;
	ymin -= ypad;
	ymax += ypad;
	for(i = 0; i < len links/2; i++){
		a := links[2*i];
		b := links[2*i+1];
		if(a < 0 || b < 0 || 2*a+1 >= len points || 2*b+1 >= len points)
			continue;
		pa := project(view,points[2*a],points[2*a+1],xmin,xmax,ymin,ymax);
		pb := project(view,points[2*b],points[2*b+1],xmin,xmax,ymin,ymax);
		im.line(pa,pb,Draw->Endsquare,Draw->Endsquare,3,bodycolour,Point(0,0));
	}
	for(i = 0; i < len points/2; i++){
		p := project(view,points[2*i],points[2*i+1],xmin,xmax,ymin,ymax);
		im.ellipse(p,4,4,0,fg,Point(0,0));
	}
}

project(view: Rect, x, y, xmin, xmax, ymin, ymax: real): Point
{
	px := view.min.x+int((x-xmin)/(xmax-xmin)*real(view.dx()));
	py := view.max.y-int((y-ymin)/(ymax-ymin)*real(view.dy()));
	return (px,py);
}

drawparameter(im: ref Image, index: int, name: string,
		value, maximum: real)
{
	width := im.r.dx()/len model.parameter;
	x := im.r.min.x+index*width;
	bandtop := im.r.max.y-ControlBandH;
	y := bandtop+24;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	fraction := (value-minima[index])/(maximum-minima[index]);
	knob := x+4+int(fraction*real(width-10));
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
