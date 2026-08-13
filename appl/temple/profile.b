implement Profileclient;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;
include "danby/profile.m";

Profileclient: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, firstcolour, secondcolour: ref Image;
modelmodule: Profile;
model: ref Profile->Model;
labels, fieldlabels: array of string;
minima, maxima: array of real;
graph: ref Plotter;
data: array of real;
samples: con 320;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || plot == nil)
		raise "fail:Profile: missing support module";
	if(tl argv == nil){
		sys->print("usage: profile model.dis [manual]\n");
		return;
	}
	modelmodule = load Profile hd tl argv;
	if(modelmodule == nil)
		raise "fail:Profile: cannot load model";
	model = modelmodule->new();
	labels = modelmodule->parameterlabels();
	minima = modelmodule->parameterminima();
	maxima = modelmodule->parametermaxima();
	fieldlabels = modelmodule->fieldlabels();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len maxima != len model.parameter || len fieldlabels != 2)
		raise "fail:Profile: metadata count";
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
	firstcolour = win.display.color(int 16rb85c38ff);
	secondcolour = win.display.color(int 16r178f86ff);
	graph = plot->new(win.image,font);
	graph.cmd("table profile radius first second -capacity 1000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour first 16rb85c38ff\n"+
		"colour second 16r178f86ff");
	recompute();
	win.reshape(Rect((0,0),(860,520)));
	win.onscreen("exact");
	win.startinput("kbd"::"ptr"::nil);
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
		'r' or 'R' => recompute();
		}
	}
}

recompute()
{
	data = modelmodule->profile(model,samples);
	if(len data != 3*samples)
		raise "fail:Profile: profile size";
	graph.cmd("profile clear");
	for(i := 0; i < samples; i++)
		graph.cmd(sys->sprint("profile append %.17g %.17g %.17g",
			data[3*i],data[3*i+1],data[3*i+2]));
}

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil ||
			pointer.xy.y <= win.image.r.max.y-55)
		return;
	n := len model.parameter;
	width := win.image.r.dx()/n;
	which := (pointer.xy.x-win.image.r.min.x)/width;
	if(which < 0)
		which = 0;
	if(which >= n)
		which = n-1;
	fraction := real(pointer.xy.x-(win.image.r.min.x+which*width))/real(width);
	if(fraction < 0.01)
		fraction = 0.01;
	model.parameter[which] = minima[which]+(maxima[which]-minima[which])*fraction;
	recompute();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	view := Rect(im.r.min.add((65,42)),im.r.max.sub((25,70)));
	firstmaximum := 1.0;
	for(i := 0; i < samples; i++){
		if(data[3*i+1] > firstmaximum)
			firstmaximum = data[3*i+1];
		if(data[3*i+2] > firstmaximum)
			firstmaximum = data[3*i+2];
	}
	graph.image = im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view radial %d %d %d %d",
		view.min.x,view.min.y,view.max.x,view.max.y));
	graph.cmd(sys->sprint("scale radial x 0 %.8g",data[3*(samples-1)]));
	graph.cmd(sys->sprint("scale radial y 0 %.8g reverse",firstmaximum));
	graph.cmd("axis radial x radius");
	graph.cmd("axis radial y normalized value");
	graph.cmd("line radial profile x radius y first colour first width 2");
	graph.cmd("line radial profile x radius y second colour second width 2");
	graph.draw();
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		modelmodule->title()+"   "+fieldlabels[0]+" / "+fieldlabels[1]);
	for(i = 0; i < len model.parameter; i++)
		drawparameter(im,i,labels[i],model.parameter[i],maxima[i]);
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
