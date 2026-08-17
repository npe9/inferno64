implement Tennis;
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
include "env.m";
 env: Env;
include "math.m";
 math: Math;
Tennis: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.0,2.5,50.0,-5.0};
dragcoef := 0.0065;
wind := 0.0;
t := 0.0;
paused := 0;
w: ref Numerics->Workspace;
histt, histy: array of real;
nh := 0;
init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	math = load Math Math->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil || math == nil)
		raise "fail:tennis: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-tennis");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Tennis trajectory", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	 histt=array[1200] of real;
	 histy=array[1200] of real;
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
	vx:=q[2]-wind;
	v:=math->sqrt(vx*vx+q[3]*q[3]);
	drag:=dragcoef*v;
	d[0]=q[2];
	d[1]=q[3];
	d[2]=-drag*vx;
	d[3]=-9.81-drag*q[3];
}
reset()
{
	y[0]=0.0;
	y[1]=2.5;
	y[2]=50.0;
	y[3]=-5.0;
	t=0.0;
	nh=0;
	paused=0;
}
step()
{
	numerics->rk4(w, rhs, t, 0.003, y);
	t+=0.003;
	if(y[1]<0.0){y[1]=0.0;
	paused=1;
	}
	if(nh<len histt){histt[nh]=y[0];
	histy[nh]=y[1];
	nh++;
	}
	else {for(i:=1;i<nh;i++){histt[i-1]=histt[i];
	histy[i-1]=histy[i];
	}histt[nh-1]=y[0];
	histy[nh-1]=y[1];
	}
}
pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		if(p.xy.x<r.min.x+r.dx()/2)dragcoef=0.02*real(p.xy.x-r.min.x)/real(r.dx()/2);
		else wind=20.0*real(p.xy.x-(r.min.x+r.dx()/2))/real(r.dx()/2);
	}else{
		y[1]=4.0*real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		if(y[1]<0.0)y[1]=0.0;
	}
	t=0.0;
	nh=0;
}
redraw()
{
	im:=win.image;
	if(im==nil)return;
	im.draw(im.r,bg,nil,Point(0,0));
	r:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	for(i:=1;i<10;i++){x:=r.min.x+i*r.dx()/10;
	y0:=r.min.y+i*r.dy()/10;
	im.line((x,r.min.y),(x,r.max.y),0,0,0,grid,Point(0,0));
	im.line((r.min.x,y0),(r.max.x,y0),0,0,0,grid,Point(0,0));
	}
	ground:=r.max.y;
	netx:=map(11.885,0.0,23.77,r.min.x,r.max.x);
	neth:=int(0.914/4.0*real(r.dy()));
	im.line((r.min.x,ground),(r.max.x,ground),0,0,2,fg,Point(0,0));
	im.line((netx,ground),(netx,ground-neth),0,0,3,accent,Point(0,0));
	for(i=1;i<nh;i++)im.line((map(histt[i-1],0.0,23.77,r.min.x,r.max.x),map(histy[i-1],0.0,4.0,r.max.y,r.min.y)),(map(histt[i],0.0,23.77,r.min.x,r.max.x),map(histy[i],0.0,4.0,r.max.y,r.min.y)),0,0,1,live,Point(0,0));
	im.ellipse((map(y[0],0.0,23.77,r.min.x,r.max.x),map(y[1],0.0,4.0,r.max.y,r.min.y)),6,6,0,accent,Point(0,0));
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Tennis trajectory — t %.2f  distance %.3f  height %.3f",t,y[0],y[1]));
	drawpar(im,0,"drag",dragcoef,0.02);
	drawpar(im,1,"wind",wind,20.0);
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
