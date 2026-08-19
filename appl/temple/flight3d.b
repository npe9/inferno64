implement Flight3dclient;

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
include "danby/flight3d.m";

Flight3dclient: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, sidecolour, plancolour: ref Image;
modelmodule: Flight3d;
model: ref Flight3d->Model;
labels: array of string;
minima: array of real;
ranges: array of real;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
finished := 0;
groundimpact := 0;
xmaximum := 10.0;
heightmaximum := 5.0;
lateralmaximum := 1.0;

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
		raise "fail:Flight3d: missing support module";
	if(tl argv == nil){
		sys->print("usage: flight3d model.dis [manual]\n");
		return;
	}
	modelpath := hd tl argv;
	modelmodule = load Flight3d modelpath;
	if(modelmodule == nil)
		raise "fail:Flight3d: cannot load "+modelpath;
	model = modelmodule->new();
	labels = modelmodule->parameterlabels();
	minima = modelmodule->parameterminima();
	ranges = modelmodule->parameterranges();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len ranges != len model.parameter)
		raise "fail:Flight3d: parameter metadata count";
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
	sidecolour = win.display.color(int 16rb85c38ff);
	plancolour = win.display.color(int 16r178f86ff);
	graph = plot->new(win.image,font);
	graph.cmd("table history time x lateral height speed -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour side 16rb85c38ff\n"+
		"colour plan 16r178f86ff");
	reset();
	win.reshape(Rect((0,0),(860,620)));
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
	if(len state != 6)
		raise "fail:Flight3d: expected x y z vx vy vz state";
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	groundimpact = 0;
	xmaximum = 10.0;
	heightmaximum = 5.0;
	lateralmaximum = 1.0;
	graph.cmd("history clear");
	record();
}

step()
{
	h := 0.005;
	old := array[] of {state[0],state[1],state[2],state[3],state[4],state[5]};
	oldt := t;
	numerics->rk4(work,rhs,t,h,state);
	t += h;
	if(state[2] < 0.0 && old[2] >= 0.0 && oldt > 0.0){
		fraction := old[2]/(old[2]-state[2]);
		for(i := 0; i < len state; i++)
			state[i] = old[i]+fraction*(state[i]-old[i]);
		state[2] = 0.0;
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
	if(state[2]*1.15 > heightmaximum)
		heightmaximum = state[2]*1.15;
	absateral := math->fabs(state[1]);
	if(absateral*1.25 > lateralmaximum)
		lateralmaximum = absateral*1.25;
	record();
}

speed(): real
{
	return math->sqrt(state[3]*state[3]+state[4]*state[4]+state[5]*state[5]);
}

record()
{
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g %.17g",
		t,state[0],state[1],state[2],speed()));
}

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	if(pointer.xy.y <= r.max.y-55)
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
	model.parameter[which] = minima[which]+(ranges[which]-minima[which])*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	content := Rect(im.r.min.add((48,38)),im.r.max.sub((18,62)));
	middle := content.min.y+content.dy()/2;
	side := Rect(content.min,(content.max.x,middle-18));
	plan := Rect((content.min.x,middle+26),content.max);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view side %d %d %d %d",
		side.min.x,side.min.y,side.max.x,side.max.y));
	graph.cmd(sys->sprint("scale side x 0 %.8g",xmaximum));
	graph.cmd(sys->sprint("scale side y 0 %.8g reverse",heightmaximum));
	graph.cmd("axis side x downrange");
	graph.cmd("axis side y height");
	graph.cmd("line side history x x y height colour side width 2");
	graph.cmd(sys->sprint("view plan %d %d %d %d",
		plan.min.x,plan.min.y,plan.max.x,plan.max.y));
	graph.cmd(sys->sprint("scale plan x 0 %.8g",xmaximum));
	graph.cmd(sys->sprint("scale plan y %.8g %.8g reverse",
		-lateralmaximum,lateralmaximum));
	graph.cmd("axis plan x downrange");
	graph.cmd("axis plan y lateral");
	graph.cmd("line plan history x x y lateral colour plan width 2");
	graph.draw();
	status := "in flight";
	if(groundimpact)
		status = "landed";
	else if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   %s   t %.3g   x %.3g   lateral %.3g   speed %.3g",
			modelmodule->title(),status,t,state[0],state[1],speed()));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im,i,labels[i],model.parameter[i],ranges[i]);
	im.flush(Draw->Flushnow);
}

drawparameter(im: ref Image, index: int, name: string,
		value, maximum: real)
{
	width := im.r.dx()/len model.parameter;
	x := im.r.min.x+index*width;
	y := im.r.max.y-40;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	fraction := (value-minima[index])/(maximum-minima[index]);
	knob := x+4+int(fraction*real(width-10));
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
