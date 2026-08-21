implement Epidemic;
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
 epidemicmodel: Populationmodel;
Epidemic: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.995,0.005,0.0};
contact := 2.2;
recovery := 0.55;
t := 0.0;
paused := 0;
w: ref Numerics->Workspace;
graph: ref Plotter;
model: ref Populationmodel->Model;
init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	epidemicmodel = load Populationmodel "/dis/danby/plugin/epidemic.dis";
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil ||
			plot == nil || epidemicmodel == nil)
		raise "fail:epidemic: missing module";
	model = epidemicmodel->new();
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-epidemic");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "SIR epidemic", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	graph=plot->new(win.image,font);
	graph.cmd("table history time S I R -capacity 12000");
	graph.cmd("colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour live 16r178f86ff\n" +
		"colour accent 16rb85c38ff");
	win.reshape(Rect((0,0),(720,450)));
	 win.onscreen("place");
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
rhs(rhsTime: real, q, d: array of real)
{
	epidemicmodel->evaluate(model,rhsTime,q,d);
}
reset()
{
	y[0]=0.995;
	y[1]=0.005;
	y[2]=0.0;
	model.parameter[0] = contact;
	model.parameter[1] = recovery;
	t=0.0;
	paused=0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g",t,y[0],y[1],y[2]));
}
step()
{
	numerics->rk4(w, rhs, t, 0.008, y);
	 t+=0.008;
	for(i:=0;i<len y;i++)if(y[i]<0.0)y[i]=0.0;
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g",t,y[0],y[1],y[2]));
}
pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		if(p.xy.x<r.min.x+r.dx()/2)contact=4.0*real(p.xy.x-r.min.x)/real(r.dx()/2);
		else recovery=4.0*real(p.xy.x-(r.min.x+r.dx()/2))/real(r.dx()/2);
		if(contact<0.02)contact=0.02;
		if(recovery<0.02)recovery=0.02;
		model.parameter[0] = contact;
		model.parameter[1] = recovery;
	}else{
		y[1]=real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		if(y[1]<0.0)y[1]=0.0;
		if(y[1]>1.0)y[1]=1.0;
		y[0]=1.0-y[1];
		y[2]=0.0;
	}
	t=0.0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g",t,y[0],y[1],y[2]));
}
redraw()
{
	im:=win.image;
	if(im==nil)return;
	im.draw(im.r,bg,nil,Point(0,0));
	r:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	graph.image=im;
	graph.cmd("clear");
	graph.cmd("content margin 45 35 18 58\nview main content");
	tmax:=t;
	if(tmax<10.0)
		tmax=10.0;
	graph.cmd(sys->sprint("scale main x 0 %.8g",tmax));
	graph.cmd("scale main y 0 1 reverse");
	graph.cmd("axis main x time");
	graph.cmd("axis main y fraction");
	graph.cmd("line main history x time y S colour live width 2");
	graph.cmd("line main history x time y I colour accent width 2");
	graph.cmd("line main history x time y R colour foreground width 2");
	graph.draw();
	x:=r.max.x-32;
	im.text((x,r.max.y-int(y[0]*real(r.dy()))-4),live,Point(0,0),font,"S");
	im.text((x,r.max.y-int(y[1]*real(r.dy()))-4),accent,Point(0,0),font,"I");
	im.text((x,r.max.y-int(y[2]*real(r.dy()))-4),fg,Point(0,0),font,"R");
	r0:=contact/recovery;
	total:=y[0]+y[1]+y[2];
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("SIR   dS=-βSI   dI=βSI-γI   R0 %.3g   S+I+R %.6f",r0,total));
	drawpar(im,0,"contact",contact,4.0);
	drawpar(im,1,"recovery",recovery,4.0);
	im.flush(Draw->Flushnow);
}
drawpar(im: ref Image,j:int,name:string,v,max:real)
{
	wid:=im.r.dx()/2;
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
