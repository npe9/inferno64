implement Arms;
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
include "liveplot.m";
 liveplot: Liveplot;
include "env.m";
 env: Env;
Arms: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.15, 0.18};
responsea := 0.45;
responseb := 0.40;
fatigue := 0.65;
grievance := 0.05;
t := 0.0;
paused := 0;
w: ref Numerics->Workspace;
histt, histy, hist2: array of real;
nh := 0;
init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	liveplot = load Liveplot Liveplot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil || liveplot == nil)
		raise "fail:Arms: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-arms");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Arms race", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16r101722ff);
	 fg=win.display.color(int 16re8edf2ff);
	grid=win.display.color(int 16r29384aff);
	 live=win.display.color(int 16r55d6beff);
	accent=win.display.color(int 16rffb454ff);
	w=numerics->workspace(len y);
	 histt=array[1200] of real;
	 histy=array[1200] of real;
	hist2=array[1200] of real;
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
	d[0]=responsea*q[1]-fatigue*q[0]+grievance;
	d[1]=responseb*q[0]-fatigue*q[1]+grievance;
}
reset()
{
	y[0]=0.65;
	y[1]=0.25;
	t=0.0;
	nh=0;
	paused=0;
}

step()
{
	numerics->rk4(w, rhs, t, 0.008, y);
	 t+=0.008;
	if(y[0]<0.0)
		y[0]=0.0;
	if(y[1]<0.0)
		y[1]=0.0;
	if(nh<len histt){
		histt[nh]=t;
		histy[nh]=y[0];
		hist2[nh]=y[1];
		nh++;
	}
	else {
		for(i:=1;i<nh;i++){
			histt[i-1]=histt[i];
			histy[i-1]=histy[i];
			hist2[i-1]=hist2[i];
		}
		histt[nh-1]=t;
		histy[nh-1]=y[0];
		hist2[nh-1]=y[1];
	}
}

pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)
		return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		wid:=r.dx()/4;
		j:=(p.xy.x-r.min.x)/wid;
		f:=real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(f<0.02)f=0.02;
		if(j==0)
			responsea=1.5*f;
		if(j==1)
			responseb=1.5*f;
		if(j==2)
			fatigue=1.5*f;
		if(j>=3)
			grievance=0.5*f;
	} else {
		y[0]=1.5*real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		y[1]=1.5*real(p.xy.x-r.min.x)/real(r.dx());
		if(y[0]<0.0)
			y[0]=0.0;
		if(y[1]<0.0)
			y[1]=0.0;
	}
	t=0.0;
	nh=0;
}
redraw()
{
	im:=win.image;
	if(im==nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	r:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	left:=Rect(r.min.add((18,36)),(r.min.x+r.dx()/2-12,r.max.y-12));
	right:=Rect((r.min.x+r.dx()/2+12,r.min.y+36),r.max.sub((18,12)));
	weaponstack(im,left,y[0],live,"SIDE A");
	weaponstack(im,right,y[1],accent,"SIDE B");
	det:=fatigue*fatigue-responsea*responseb;
	status:="stable equilibrium";
	if(det<=0.0)
		status="unstable escalation";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Arms race — t %.2f  arsenal A %.4g  arsenal B %.4g",t,y[0],y[1]));
	im.text(r.min.add((10,18)),fg,Point(0,0),font,status);
	drawpar(im,0,"response A",responsea,1.5);
	drawpar(im,1,"response B",responseb,1.5);
	drawpar(im,2,"fatigue",fatigue,1.5);
	drawpar(im,3,"grievance",grievance,0.5);
	im.flush(Draw->Flushnow);
}

weaponstack(im: ref Image, r: Rect, value: real, colour: ref Image, label: string)
{
	if(value<0.0)
		value=0.0;
	n:=int(value/0.025);
	if(n>60)
		n=60;
	im.text(r.min.add((4,14)),fg,Point(0,0),font,sys->sprint("%s  %.3f",label,value));
	for(i:=0;i<n;i++){
		row:=i/5;
		x:=r.min.x+(i%5)*r.dx()/5+5;
		y0:=r.max.y-row*22-8;
		if(y0<r.min.y+25)
			break;
		im.draw(Rect((x,y0-4),(x+r.dx()/5-12,y0+5)),colour,nil,Point(0,0));
	}
}

drawpar(im: ref Image,j:int,name:string,v,max:real)
{
	wid:=im.r.dx()/4;
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
