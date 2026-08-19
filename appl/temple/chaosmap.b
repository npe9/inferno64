implement Chaosmapapp;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "danby/chaosmap.m";
	chaosmap: Chaosmap;
include "env.m";
	env: Env;

Chaosmapapp: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
background, foreground, grid, live, accent: ref Image;
graph: ref Plotter;
parameter := 3.72;
initial := 0.217;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	plot = load Plot Plot->PATH;
	chaosmap = load Chaosmap Chaosmap->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil ||
			plot == nil || chaosmap == nil)
		raise "fail:chaosmap: missing module";
	if(env != nil){
		env->clone();
		env->setenv("wmman","danby-chaosmap");
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,"Chaos in difference equations",Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	background = win.display.color(int 16rf4f0e7ff);
	foreground = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	live = win.display.color(int 16r178f86ff);
	accent = win.display.color(int 16rb85c38ff);
	graph = plot->new(win.image,font);
	declareplot();
	fillbifurcation();
	fillselected();
	win.reshape(Rect((0,0),(900,570)));
	win.onscreen("place");
	win.startinput("kbd"::"ptr"::nil);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointer := <-win.ctxt.ptr =>
		win.pointer(*pointer);
		if(pointer.buttons&1){
			setpointer(pointer.xy);
			fillselected();
			redraw();
		}
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		'r' or 'R' =>
			parameter = 3.72;
			initial = 0.217;
			fillselected();
			redraw();
		}
	}
}

declareplot()
{
	error := graph.cmd(
		"table bifurcation parameter value -capacity 24000\n" +
		"table map x y -capacity 256\n" +
		"table diagonal x y -capacity 2\n" +
		"table cobweb x y -capacity 512\n" +
		"table selected parameter value -capacity 2\n" +
		"colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour live 16r178f86ff\n" +
		"colour accent 16rb85c38ff");
	if(error != nil)
		raise "fail:chaosmap: " + error;
}

fillbifurcation()
{
	graph.cmd("bifurcation clear");
	for(ir := 0; ir <= 180; ir++){
		r := 2.8+1.2*real(ir)/180.0;
		x := 0.217;
		for(i := 0; i < 500; i++)
			x = chaosmap->step(r,x);
		command := "bifurcation append";
		for(i = 0; i < 80; i++){
			x = chaosmap->step(r,x);
			command += sys->sprint(" %.9g %.9g",r,x);
		}
		error := graph.cmd(command);
		if(error != nil)
			raise "fail:chaosmap: " + error;
	}
	graph.cmd("diagonal clear\n" +
		"diagonal append 0 0 1 1");
}

fillselected()
{
	graph.cmd("map clear\n" +
		"cobweb clear\n" +
		"selected clear");
	for(i := 0; i <= 160; i++){
		x := real(i)/160.0;
		graph.cmd(sys->sprint("map append %.9g %.9g",
			x,chaosmap->step(parameter,x)));
	}
	x := initial;
	graph.cmd(sys->sprint("cobweb append %.9g 0",x));
	for(i = 0; i < 80; i++){
		next := chaosmap->step(parameter,x);
		graph.cmd(sys->sprint("cobweb append %.9g %.9g %.9g %.9g",
			x,next,next,next));
		x = next;
	}
	graph.cmd(sys->sprint("selected append %.9g 0 %.9g 1",
		parameter,parameter));
}

setpointer(point: Point)
{
	if(win.image == nil)
		return;
	r := win.image.r;
	if(point.y >= r.max.y-48){
		fraction := real(point.x-r.min.x)/real(r.dx());
		if(fraction < 0.0)
			fraction = 0.0;
		if(fraction > 1.0)
			fraction = 1.0;
		parameter = 2.8+1.2*fraction;
	}else if(point.x > r.min.x+r.dx()*2/3){
		initial = real(r.max.y-55-point.y)/real(r.dy()-95);
		if(initial < 0.001)
			initial = 0.001;
		if(initial > 0.999)
			initial = 0.999;
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
	left := Rect(image.r.min.add((50,38)),
		(image.r.min.x+image.r.dx()*2/3-20,image.r.max.y-58));
	right := Rect((image.r.min.x+image.r.dx()*2/3+35,image.r.min.y+38),
		(image.r.max.x-18,image.r.max.y-58));
	graph.cmd(sys->sprint(
		"view bif %d %d %d %d\n" +
		"scale bif x 2.8 4\n" +
		"scale bif y 0 1 reverse\n" +
		"axis bif x parameter-r grid\n" +
		"axis bif y long-run-x grid\n" +
		"view cob %d %d %d %d\n" +
		"scale cob x 0 1\n" +
		"scale cob y 0 1 reverse\n" +
		"axis cob x x[n] grid\n" +
		"axis cob y x[n+1] grid",
		left.min.x,left.min.y,left.max.x,left.max.y,
		right.min.x,right.min.y,right.max.x,right.max.y));
	graph.cmd(
		"point bif bifurcation x parameter y value colour foreground radius 1\n" +
		"line bif selected x parameter y value colour accent width 1\n" +
		"line cob map x x y y colour live width 2\n" +
		"line cob diagonal x x y y colour grid width 1\n" +
		"line cob cobweb x x y y colour accent width 1");
	graph.draw();
	lyapunov := chaosmap->lyapunov(parameter,initial,500,1000);
	classification := "periodic";
	if(lyapunov > 0.0)
		classification = "chaotic";
	image.text(image.r.min.add((12,19)),foreground,Point(0,0),font,
		sys->sprint("x[n+1]=r x[n](1-x[n])   r %.5g   x0 %.5g   lambda %.5g %s",
			parameter,initial,lyapunov,classification));
	drawtrack(image);
	image.flush(Draw->Flushnow);
}

drawtrack(image: ref Image)
{
	y := image.r.max.y-18;
	left := image.r.min.x+12;
	right := image.r.max.x-12;
	image.line((left,y),(right,y),0,0,2,grid,Point(0,0));
	x := left+int((parameter-2.8)/1.2*real(right-left));
	image.ellipse((x,y),5,5,0,accent,Point(0,0));
	image.text((left,image.r.max.y-34),foreground,Point(0,0),font,
		"drag: parameter r; drag cobweb: initial x");
}
