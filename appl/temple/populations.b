implement Populations;

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

Populations: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, marker: ref Image;
palette: array of ref Image;
palettevalue := array[] of {
	int 16r178f86ff, int 16rb85c38ff, int 16r526fa8ff,
	int 16r9673a6ff, int 16rd49a32ff, int 16r6f8f3dff
};
modelmodule: Populationmodel;
model: ref Populationmodel->Model;
labels, parameterlabels: array of string;
parameterranges: array of real;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
displaymax := 1.0;
modeltitle: string;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil ||
			numerics == nil || plot == nil)
		raise "fail:Populations: missing support module";
	if(tl argv == nil){
		sys->print("usage: populations model.dis [manual]\n");
		return;
	}
	modelpath := hd tl argv;
	modelmodule = load Populationmodel modelpath;
	if(modelmodule == nil)
		raise "fail:Populations: cannot load " + modelpath;
	model = modelmodule->new();
	modeltitle = modelmodule->title();
	labels = modelmodule->statelabels();
	parameterlabels = modelmodule->parameterlabels();
	parameterranges = modelmodule->parameterranges();
	if(len labels != len model.initial)
		raise "fail:Populations: state label count";
	if(len parameterlabels != len model.parameter ||
			len parameterranges != len model.parameter)
		raise "fail:Populations: parameter metadata count";
	if(env != nil){
		env->clone();
		manual := "danby-" + hd argv;
		if(tl tl argv != nil)
			manual = hd tl tl argv;
		env->setenv("wmman",manual);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,modeltitle,Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	marker = win.display.color(int 16r20272cff);
	palette = array[len palettevalue] of ref Image;
	for(i := 0; i < len palette; i++)
		palette[i] = win.display.color(palettevalue[i]);
	state = array[len model.initial] of real;
	work = numerics->workspace(len state);
	graph = plot->new(win.image,font);
	table := "table history time";
	for(i = 0; i < len state; i++)
		table += " state" + string i;
	graph.cmd(table + " -capacity 16000");
	colours := "colour grid 16rd6d0c4ff";
	for(i = 0; i < len palettevalue; i++)
		colours += sys->sprint("\ncolour state%d 16r%ux",i,palettevalue[i]);
	graph.cmd(colours);
	reset();
	win.reshape(Rect((0,0),(800,500)));
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
			for(i = 0; i < 4; i++)
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
	for(i := 0; i < len state; i++)
		state[i] = model.initial[i];
	t = 0.0;
	paused = 0;
	displaymax = 1.0;
	for(i = 0; i < len state; i++)
		if(state[i]*1.15 > displaymax)
			displaymax = state[i]*1.15;
	graph.cmd("history clear");
	record();
}

step()
{
	numerics->rk4(work,rhs,t,0.008,state);
	t += 0.008;
	for(i := 0; i < len state; i++){
		if(state[i] < 0.0)
			state[i] = 0.0;
		if(state[i]*1.15 > displaymax)
			displaymax = state[i]*1.15;
	}
	record();
}

record()
{
	command := sys->sprint("history append %.17g",t);
	for(i := 0; i < len state; i++)
		command += sys->sprint(" %.17g",state[i]);
	graph.cmd(command);
}

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	controltop := r.max.y-(controlrows()*42+12);
	if(pointer.xy.y > controltop){
		n := len model.parameter;
		if(n == 0)
			return;
		row := (pointer.xy.y-controltop)/42;
		if(row >= controlrows())
			row = controlrows()-1;
		first := row*6;
		columns := n-first;
		if(columns > 6)
			columns = 6;
		width := r.dx()/columns;
		which := first+(pointer.xy.x-r.min.x)/width;
		if(which < 0)
			which = 0;
		if(which >= n)
			which = n-1;
		column := which-first;
		fraction := real(pointer.xy.x-(r.min.x+column*width))/real(width);
		if(fraction < 0.01)
			fraction = 0.01;
		model.parameter[which] = parameterranges[which]*fraction;
		reset();
		return;
	}
	bararea := Rect((r.max.x-180,r.min.y+35),
		(r.max.x-12,r.max.y-(controlrows()*42+30)));
	if(pointer.xy.in(bararea)){
		height := bararea.dy()/len state;
		which := (pointer.xy.y-bararea.min.y)/height;
		fraction := real(pointer.xy.x-bararea.min.x)/real(bararea.dx());
		state[which] = displaymax*fraction;
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
	tmax := t;
	if(tmax < 10.0)
		tmax = 10.0;
	graph.image = im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("content margin 48 38 200 %d\nview historyplot content",
		controlrows()*42+20));
	graph.cmd(sys->sprint("scale historyplot x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale historyplot y 0 %.8g reverse",displaymax));
	graph.cmd("axis historyplot x time");
	graph.cmd("axis historyplot y quantity");
	for(i := 0; i < len state; i++)
		graph.cmd(sys->sprint(
			"line historyplot history x time y state%d colour state%d width 2",
			i,i%len palette));
	graph.draw();
	drawstatebars(im);
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   t %.2f",modeltitle,t));
	for(i = 0; i < len model.parameter; i++)
		drawparameter(im,i,parameterlabels[i],
			model.parameter[i],parameterranges[i]);
	im.flush(Draw->Flushnow);
}

drawstatebars(im: ref Image)
{
	r := Rect((im.r.max.x-180,im.r.min.y+35),
		(im.r.max.x-12,im.r.max.y-(controlrows()*42+30)));
	height := r.dy()/len state;
	for(i := 0; i < len state; i++){
		y := r.min.y+i*height;
		im.text((r.min.x,y+font.height),fg,Point(0,0),font,
			sys->sprint("%s %.4g",labels[i],state[i]));
		track := Rect((r.min.x,y+font.height+4),
			(r.max.x,y+height-5));
		im.draw(track,grid,nil,Point(0,0));
		filled := track;
		filled.max.x = filled.min.x+
			int(real(track.dx())*state[i]/displaymax);
		im.draw(filled,palette[i%len palette],nil,Point(0,0));
	}
}

drawparameter(im: ref Image, index: int,
		name: string, value, maximum: real)
{
	row := index/6;
	column := index%6;
	remaining := len model.parameter-row*6;
	columns := remaining;
	if(columns > 6)
		columns = 6;
	width := im.r.dx()/columns;
	x := im.r.min.x+column*width;
	y := im.r.max.y-controlrows()*42+row*42+10;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	knob := x+4+int(value/maximum*real(width-10));
	im.ellipse((knob,y),4,4,0,marker,Point(0,0));
	im.text((x+4,im.r.max.y-17),fg,Point(0,0),font,
		sys->sprint("%s %.3g",name,value));
}

controlrows(): int
{
	rows := (len model.parameter+5)/6;
	if(rows < 1)
		rows = 1;
	return rows;
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}
