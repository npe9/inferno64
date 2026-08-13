implement Harvest;
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
include "math.m";
 math: Math;
include "plot.m";
 plot: Plot;
	Plotter: import plot;
include "env.m";
 env: Env;
Harvest: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.75};
growth := 1.0;
capacity := 1.0;
take := 0.12;
t := 0.0;
paused := 0;
w: ref Numerics->Workspace;
graph: ref Plotter;
init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	math = load Math Math->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil || math == nil || plot == nil)
		raise "fail:harvest: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-harvest");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Harvested population", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	graph=plot->new(win.image,font);
	graph.cmd("table history time population -capacity 12000");
	graph.cmd("table equilibrium time population -capacity 2");
	graph.cmd("colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour live 16r178f86ff\n" +
		"colour accent 16rb85c38ff");
	win.reshape(Rect((0,0),(720,450)));
	 win.onscreen("exact");
	 win.startinput("kbd"::"ptr"::nil);
	ticks:=chan of int;
	 spawn timer(ticks);
	 redraw();
	for(;;) alt {
	ctl:=<-win.ctl or ctl=<-win.ctxt.ctl => win.wmctl(ctl);
	 redraw();
	p:=<-win.ctxt.ptr => win.pointer(*p);
	 pointer(p);
	 redraw();
	k:=<-win.ctxt.kbd => case k {
		16r1b or 'q' or 'Q' => exit;
		' ' => paused=!paused;
		'r' or 'R' => reset();
		'.' => if(paused) step();
	}
	<-ticks => if(!paused){for(i:=0;i<4;i++)step();
	} redraw();
	}
}
rhs(nil: real, q, d: array of real)
{
	d[0]=growth*q[0]*(1.0-q[0]/capacity)-take;
}
reset()
{
	y[0]=0.75;
	 t=0.0;
	 paused=0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g",t,y[0]));
}
step()
{
	numerics->rk4(w, rhs, t, 0.008, y);
	 t+=0.008;
	if(y[0]<0.0)y[0]=0.0;
	graph.cmd(sys->sprint("history append %.17g %.17g",t,y[0]));
}
pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		wid:=r.dx()/3;
		j:=(p.xy.x-r.min.x)/wid;
		f:=real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(j==0)
			growth=3.0*f;
		if(j==1)
			capacity=2.0*f;
		if(j>=2)
			take=0.5*f;
		if(growth<0.02)growth=0.02;
		if(capacity<0.02)capacity=0.02;
	}else{
		y[0]=capacity*real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		if(y[0]<0.0)y[0]=0.0;
		if(y[0]>capacity)y[0]=capacity;
	}
	t=0.0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g",t,y[0]));
}
redraw()
{
	im:=win.image;
	if(im==nil)return;
	im.draw(im.r,bg,nil,Point(0,0));
	r:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	graph.image=im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view main %d %d %d %d",r.min.x,r.min.y,r.max.x,r.max.y));
	tmax:=t;
	if(tmax<10.0)
		tmax=10.0;
	ymax:=capacity*1.1;
	if(y[0]*1.1>ymax)
		ymax=y[0]*1.1;
	graph.cmd(sys->sprint("scale main x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale main y 0 %.8g reverse",ymax));
	graph.cmd("axis main x time");
	graph.cmd("axis main y population");
	graph.cmd("equilibrium clear");
	disc:=1.0-4.0*take/(growth*capacity);
	if(disc>=0.0){
		stable:=capacity*(1.0+math->sqrt(disc))/2.0;
		graph.cmd(sys->sprint("equilibrium append 0 %.17g",stable));
		graph.cmd(sys->sprint("equilibrium append %.17g %.17g",tmax,stable));
	}
	graph.cmd("line main equilibrium x time y population colour accent width 1");
	graph.cmd("line main history x time y population colour live width 2");
	graph.draw();
	# The equilibrium disappears once take exceeds rK/4; show that threshold.
	status := "sustainable";
	if(take > growth*capacity/4.0)
		status = "collapse: harvest exceeds maximum growth";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Harvested population   dN/dt=rN(1-N/K)-H   N %.3g   %s",y[0],status));
	drawpar(im,0,"growth",growth,3.0);
	drawpar(im,1,"capacity",capacity,2.0);
	drawpar(im,2,"harvest",take,0.5);
	im.flush(Draw->Flushnow);
}
drawpar(im: ref Image,j:int,name:string,v,max:real)
{
	wid:=im.r.dx()/3;
	x:=im.r.min.x+j*wid;
	 yy:=im.r.max.y-39;
	im.line((x+4,yy),(x+wid-6,yy),0,0,2,grid,Point(0,0));
	k:=x+4+int(v/max*real(wid-10));
	im.ellipse((k,yy),4,4,0,accent,Point(0,0));
	im.text((x+4,im.r.max.y-17),fg,Point(0,0),font,sys->sprint("%s %.3g",name,v));
}
map(v,lo,hi:real,a,b:int):int {if(hi==lo)return a;
return a+int((v-lo)*real(b-a)/(hi-lo));
}
timer(c:chan of int){for(;;){sys->sleep(25);
c<-=1;
}}
