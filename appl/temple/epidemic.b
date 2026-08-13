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
include "env.m";
 env: Env;
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
histt, hists, histi, histr: array of real;
nh := 0;
init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil)
		raise "fail:epidemic: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-epidemic");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "SIR epidemic", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16r101722ff);
	 fg=win.display.color(int 16re8edf2ff);
	grid=win.display.color(int 16r29384aff);
	 live=win.display.color(int 16r55d6beff);
	accent=win.display.color(int 16rffb454ff);
	w=numerics->workspace(len y);
	histt=array[1200] of real;
	hists=array[1200] of real;
	histi=array[1200] of real;
	histr=array[1200] of real;
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
	inf:=contact*q[0]*q[1];
	rec:=recovery*q[1];
	d[0]=-inf;
	d[1]=inf-rec;
	d[2]=rec;
}
reset()
{
	y[0]=0.995;
	y[1]=0.005;
	y[2]=0.0;
	t=0.0;
	nh=0;
	paused=0;
}
step()
{
	numerics->rk4(w, rhs, t, 0.008, y);
	 t+=0.008;
	for(i:=0;i<len y;i++)if(y[i]<0.0)y[i]=0.0;
	if(nh<len histt){histt[nh]=t;
	hists[nh]=y[0];
	histi[nh]=y[1];
	histr[nh]=y[2];
	nh++;
	}
	else {for(i=1;i<nh;i++){histt[i-1]=histt[i];
	hists[i-1]=hists[i];
	histi[i-1]=histi[i];
	histr[i-1]=histr[i];
	}histt[nh-1]=t;
	hists[nh-1]=y[0];
	histi[nh-1]=y[1];
	histr[nh-1]=y[2];
	}
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
	}else{
		y[1]=real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		if(y[1]<0.0)y[1]=0.0;
		if(y[1]>1.0)y[1]=1.0;
		y[0]=1.0-y[1];
		y[2]=0.0;
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
	for(i=1;i<nh;i++){x0:=map(histt[i-1],0.0,10.0,r.min.x,r.max.x);
	x1:=map(histt[i],0.0,10.0,r.min.x,r.max.x);
	im.line((x0,map(hists[i-1],0.0,1.0,r.max.y,r.min.y)),(x1,map(hists[i],0.0,1.0,r.max.y,r.min.y)),0,0,1,live,Point(0,0));
	im.line((x0,map(histi[i-1],0.0,1.0,r.max.y,r.min.y)),(x1,map(histi[i],0.0,1.0,r.max.y,r.min.y)),0,0,1,accent,Point(0,0));
	im.line((x0,map(histr[i-1],0.0,1.0,r.max.y,r.min.y)),(x1,map(histr[i],0.0,1.0,r.max.y,r.min.y)),0,0,1,fg,Point(0,0));
	}
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("SIR epidemic — t %.2f  S %.3f  I %.3f  R %.3f",t,y[0],y[1],y[2]));
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

