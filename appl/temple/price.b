implement Price;
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
Price: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.25};
demand := 1.0;
supply := 0.8;
adjustment := 0.9;
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
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil || plot == nil)
		raise "fail:price: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-price");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Price growth", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	graph=plot->new(win.image,font);
	graph.cmd("table history time price -capacity 12000");
	graph.cmd("table demand quantity price -capacity 40");
	graph.cmd("table supply quantity price -capacity 40");
	graph.cmd("table price quantity price -capacity 2");
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
		16r1b or 'q' or 'Q' => win.wmctl("exit");
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
	d[0]=adjustment*(demand*(1.0-q[0])-supply*q[0]);
}
reset()
{
	y[0]=0.25;
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
		if(j==0)demand=2.0*f;
		if(j==1)supply=2.0*f;
		if(j>=2)adjustment=2.0*f;
	}else{
		y[0]=real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		if(y[0]<0.0)y[0]=0.0;
		if(y[0]>1.0)y[0]=1.0;
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
	content:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	xsplit:=content.min.x+content.dx()*55/100;
	market:=Rect(content.min,(xsplit-22,content.max.y));
	timeplot:=Rect((xsplit+30,content.min.y),content.max);
	graph.image=im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view market %d %d %d %d",market.min.x,market.min.y,market.max.x,market.max.y));
	graph.cmd("scale market x 0 1");
	graph.cmd("scale market y 0 1 reverse");
	graph.cmd("axis market x quantity");
	graph.cmd("axis market y price");
	graph.cmd("demand clear");
	graph.cmd("supply clear");
	for(i:=0;i<40;i++){
		q:=real(i)/39.0;
		graph.cmd(sys->sprint("demand append %.17g %.17g",q,1.0-q));
		graph.cmd(sys->sprint("supply append %.17g %.17g",q,q));
	}
	graph.cmd("price clear");
	graph.cmd(sys->sprint("price append %.17g %.17g",0.0,y[0]));
	graph.cmd(sys->sprint("price append %.17g %.17g",1.0,y[0]));
	graph.cmd("line market demand x quantity y price colour live width 2");
	graph.cmd("line market supply x quantity y price colour accent width 2");
	graph.cmd("line market price x quantity y price colour foreground width 1");
	tmax:=t;
	if(tmax<10.0)
		tmax=10.0;
	graph.cmd(sys->sprint("view time %d %d %d %d",timeplot.min.x,timeplot.min.y,timeplot.max.x,timeplot.max.y));
	graph.cmd(sys->sprint("scale time x 0 %.8g",tmax));
	graph.cmd("scale time y 0 1 reverse");
	graph.cmd("axis time x time");
	graph.cmd("axis time y price");
	graph.cmd("line time history x time y price colour foreground width 2");
	graph.draw();
	eq:=demand/(demand+supply);
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Price adjustment   dp/dt=a[D(1-p)-Sp]   p %.3g   equilibrium %.3g",y[0],eq));
	drawpar(im,0,"demand",demand,2.0);
	drawpar(im,1,"supply",supply,2.0);
	drawpar(im,2,"adjustment",adjustment,2.0);
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
