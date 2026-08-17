implement Firms;
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
Firms: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.65, 0.35};
growa := 1.2;
growb := 0.9;
coupling := 0.5;
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
		raise "fail:Firms: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-firms");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Coupled firms", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	graph=plot->new(win.image,font);
	graph.cmd("table history time A B -capacity 12000");
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
	<-ticks =>
		if(!paused){
			for(i:=0;i<4;i++)
				step();
		}
		redraw();
	}
}
rhs(nil: real, q, d: array of real)
{
	d[0]=growa*q[0]*(1.0-q[0])-coupling*q[0]*q[1];
	d[1]=growb*q[1]*(1.0-q[1])-coupling*q[0]*q[1];
}
reset()
{
	y[0]=0.65;
	y[1]=0.25;
	t=0.0;
	paused=0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",t,y[0],y[1]));
}
step()
{
	numerics->rk4(w, rhs, t, 0.008, y);
	 t+=0.008;
	if(y[0]<0.0)y[0]=0.0;
	if(y[1]<0.0)y[1]=0.0;
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",t,y[0],y[1]));
}
pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		wid:=r.dx()/3;
		j:=(p.xy.x-r.min.x)/wid;
		f:=real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(f<0.02)f=0.02;
		if(j==0)
			growa=2.0*f;
		if(j==1)
			growb=2.0*f;
		if(j>=2)
			coupling=2.0*f;
	}else{
		y[0]=1.5*real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		y[1]=1.5*real(p.xy.x-r.min.x)/real(r.dx());
		if(y[0]<0.0)y[0]=0.0;
		if(y[1]<0.0)y[1]=0.0;
	}
	t=0.0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",t,y[0],y[1]));
}
redraw()
{
	im:=win.image;
	if(im==nil)return;
	im.draw(im.r,bg,nil,Point(0,0));
	r:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	drawplots(im,r,"firm-A","firm-B");
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Coupled firms — t %.2f  firm A share %.4g  firm B share %.4g",t,y[0],y[1]));
	drawpar(im,0,"growth A",growa,2.0);
	drawpar(im,1,"growth B",growb,2.0);
	drawpar(im,2,"coupling",coupling,2.0);
	im.flush(Draw->Flushnow);
}

drawplots(im: ref Image, r: Rect, alabel, blabel: string)
{
	graph.image=im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view phase %d %d %d %d",r.min.x,r.min.y,r.max.x,r.max.y));
	graph.cmd("scale phase x 0 1.5");
	graph.cmd("scale phase y 0 1.5 reverse");
	graph.cmd("axis phase x "+alabel);
	graph.cmd("axis phase y "+blabel);
	graph.cmd("line phase history x A y B colour foreground width 2");
	graph.draw();
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
timer(c:chan of int)
{
	for(;;){
		sys->sleep(25);
		c<-=1;
	}
}
