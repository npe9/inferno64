implement Orbitalclient;

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
include "danby/orbital.m";

Orbitalclient: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Ntrail: con 1600;

win: ref Window;
font: ref Font;
bg, fg, grid, firstcolour, secondcolour: ref Image;
bodycolour: array of ref Image;
modelmodule: Orbital;
model: ref Orbital->Model;
labels, bodylabels, observablelabels: array of string;
minima, maxima: array of real;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
trail: array of array of real;
trailcount := 0;
trailnext := 0;
t := 0.0;
paused := 0;
finished := 0;
observationmaximum := array[] of {1.0,1.0};

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
		raise "fail:Orbital: missing support module";
	if(tl argv == nil){
		sys->print("usage: orbital model.dis [manual]\n");
		return;
	}
	modelmodule = load Orbital hd tl argv;
	if(modelmodule == nil)
		raise "fail:Orbital: cannot load model";
	model = modelmodule->new();
	labels = modelmodule->parameterlabels();
	minima = modelmodule->parameterminima();
	maxima = modelmodule->parametermaxima();
	bodylabels = modelmodule->bodylabels();
	observablelabels = modelmodule->observablelabels();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len maxima != len model.parameter || len bodylabels != len model.mass)
		raise "fail:Orbital: metadata count";
	if(len observablelabels != 2)
		raise "fail:Orbital: expected two observables";
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
	bg = win.display.color(int 16r080d18ff);
	fg = win.display.color(int 16re7edf7ff);
	grid = win.display.color(int 16r394457ff);
	firstcolour = win.display.color(int 16r4ec9b0ff);
	secondcolour = win.display.color(int 16rf2b84bff);
	bodycolour = array[] of {
		win.display.color(int 16rf2b84bff),
		win.display.color(int 16r4ec9b0ff),
		win.display.color(int 16r70a5ffff),
		win.display.color(int 16re77c8eff),
		win.display.color(int 16rc792eaff),
		win.display.color(int 16r9dd274ff)
	};
	graph = plot->new(win.image,font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16re7edf7ff\n"+
		"colour grid 16r394457ff\n"+
		"colour first 16r4ec9b0ff\n"+
		"colour second 16rf2b84bff");
	trail = array[Ntrail] of array of real;
	reset();
	win.reshape(Rect((0,0),(920,580)));
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
	if(len state != 4*len model.mass)
		raise "fail:Orbital: state size";
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	trailcount = 0;
	trailnext = 0;
	observationmaximum[0] = 1.0;
	observationmaximum[1] = 1.0;
	graph.cmd("history clear");
	record();
}

step()
{
	numerics->rk4(work,rhs,t,0.0025,state);
	t += 0.0025;
	if(t >= modelmodule->maxtime(model)){
		finished = 1;
		paused = 1;
	}
	record();
}

record()
{
	positions := array[2*len model.mass] of real;
	for(i := 0; i < len model.mass; i++){
		positions[2*i] = state[4*i];
		positions[2*i+1] = state[4*i+1];
	}
	trail[trailnext] = positions;
	trailnext = (trailnext+1)%Ntrail;
	if(trailcount < Ntrail)
		trailcount++;
	values := modelmodule->observables(model,state);
	for(i = 0; i < 2; i++){
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
	model.parameter[which] = minima[which]+(maxima[which]-minima[which])*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	content := Rect(im.r.min.add((25,38)),im.r.max.sub((18,62)));
	middle := content.min.x+(content.dx()*3)/5;
	orbitview := Rect(content.min,(middle-20,content.max.y));
	draworbits(im,orbitview);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 25 38 18 62\n" +
		"split content x orbitview 3 plotview 2 gutter 55\n" +
		"view diagnostics plotview");
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	ymax := observationmaximum[0];
	if(observationmaximum[1] > ymax)
		ymax = observationmaximum[1];
	graph.cmd(sys->sprint("scale diagnostics x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale diagnostics y %.8g %.8g reverse",-ymax,ymax));
	graph.cmd("axis diagnostics x time");
	graph.cmd("axis diagnostics y value");
	graph.cmd("line diagnostics history x time y first colour first width 2");
	graph.cmd("line diagnostics history x time y second colour second width 2");
	graph.draw();
	values := modelmodule->observables(model,state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   %s   t %.3g   %s %.4g   %s %.4g",
			modelmodule->title(),status,t,observablelabels[0],values[0],
			observablelabels[1],values[1]));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im,i,labels[i],model.parameter[i],maxima[i]);
	im.flush(Draw->Flushnow);
}

# draworbits keeps the most massive body (the "planet") pinned at the
# centre of view and lets the SCALE do all the work as the orbit grows
# or shrinks - not an independent x/y bounding box mapped straight onto
# the view rect, which was the bug: that box's own centre drifts as
# the trail's extent changes even though the planet's own position
# hasn't moved, so the planet visibly wandered around the screen
# instead of staying put while the view zoomed. A single uniform scale
# (not separate x and y ranges) also keeps a circular orbit looking
# circular instead of stretched to fill whichever axis has more room.
# Same fix as danby-aerobraking(1)'s own draworbits(), which this file
# is the likely origin of (or vice versa) - kept independent per file,
# matching how this tree already treats aerobraking as deliberately
# standalone rather than sharing code with this harness.
draworbits(im: ref Image, view: Rect)
{
	focus := 0;
	for(i := 1; i < len model.mass; i++)
		if(model.mass[i] > model.mass[focus])
			focus = i;

	# extent: the largest distance any trail point sits from the
	# FOCUS body's own position at that same instant - not from the
	# focus body's current position, so a system whose "planet" isn't
	# perfectly fixed (unlike aerobraking's own) still reads correctly.
	extent := 0.1;
	for(k := 0; k < trailcount; k++){
		index := trailnext-trailcount+k;
		if(index < 0)
			index += Ntrail;
		positions := trail[index];
		fx := positions[2*focus];
		fy := positions[2*focus+1];
		for(i = 0; i < len model.mass; i++){
			dx := positions[2*i]-fx;
			if(dx < 0.0)
				dx = -dx;
			if(dx > extent)
				extent = dx;
			dy := positions[2*i+1]-fy;
			if(dy < 0.0)
				dy = -dy;
			if(dy > extent)
				extent = dy;
		}
	}
	extent *= 1.24; # same total padding the old x/y-range version used

	half := view.dx();
	if(view.dy() < half)
		half = view.dy();
	scale := real(half)/(2.0*extent);
	centre := Point((view.min.x+view.max.x)/2,(view.min.y+view.max.y)/2);

	for(i = 0; i < len model.mass; i++){
		haveprevious := 0;
		previous := Point(0,0);
		for(k = 0; k < trailcount; k++){
			index := trailnext-trailcount+k;
			if(index < 0)
				index += Ntrail;
			positions := trail[index];
			point := project(centre,scale,positions[2*i],positions[2*i+1],
				positions[2*focus],positions[2*focus+1]);
			if(haveprevious)
				im.line(previous,point,0,0,1,bodycolour[i%len bodycolour],Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := project(centre,scale,state[4*i],state[4*i+1],
			state[4*focus],state[4*focus+1]);
		radius := 4;
		if(model.mass[i] > 0.1)
			radius = 7;
		im.ellipse(point,radius,radius,0,bodycolour[i%len bodycolour],Point(0,0));
		im.text(point.add((radius+3,-3)),fg,Point(0,0),font,bodylabels[i]);
	}
}

# (x,y) relative to the focus body's own position (cx,cy) at the SAME
# instant, scaled uniformly and offset from view centre - so (cx,cy)
# itself always lands exactly on centre, every frame, regardless of
# scale: the focus body never moves on screen, only the scale changes.
project(centre: Point, scale: real, x, y, cx, cy: real): Point
{
	return centre.add((int((x-cx)*scale), -int((y-cy)*scale)));
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
