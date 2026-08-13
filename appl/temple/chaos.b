implement Chaos;
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
Chaos: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.1, 0.0, 0.0};
sigma := 10.0;
rho := 28.0;
beta := 8.0/3.0;
t := 0.0;
paused := 0;
w: ref Numerics->Workspace;
histx, histz: array of real;
nh := 0;
init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil)
		raise "fail:chaos: missing module";
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-chaos");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Lorenz chaos", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16r101722ff);
	 fg=win.display.color(int 16re8edf2ff);
	grid=win.display.color(int 16r29384aff);
	 live=win.display.color(int 16r55d6beff);
	accent=win.display.color(int 16rffb454ff);
	w=numerics->workspace(len y);
	histx=array[1200] of real;
	histz=array[1200] of real;
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
	d[0] = sigma*(q[1]-q[0]);
	d[1] = q[0]*(rho-q[2])-q[1];
	d[2] = q[0]*q[1]-beta*q[2];
}
reset()
{
	y[0]=0.1;
	y[1]=0.0;
	y[2]=0.0;
	 t=0.0;
	 nh=0;
	 paused=0;
}
step()
{
	numerics->rk4(w, rhs, t, 0.0025, y);
	t+=0.0025;
	if(nh<len histx){histx[nh]=y[0];
	histz[nh]=y[2];
	nh++;
	}
	else {
		for(i:=1;i<nh;i++){
			histx[i-1]=histx[i];
			histz[i-1]=histz[i];
		}
		histx[nh-1]=y[0];
		histz[nh-1]=y[2];
	}
}
pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		wid:=r.dx()/3;
		j:=(p.xy.x-r.min.x)/wid;
		f:=real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(f<0.02)
			f=0.02;
		if(j==0)
			sigma=25.0*f;
		if(j==1)
			rho=50.0*f;
		if(j>=2)
			beta=5.0*f;
	}else{
		y[0]=30.0*(real(r.max.y-58-p.xy.y)/real(r.dy()-93)-0.5);
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
	for(i:=1;i<10;i++){
		x:=r.min.x+i*r.dx()/10;
		y0:=r.min.y+i*r.dy()/10;
		im.line((x,r.min.y),(x,r.max.y),0,0,0,grid,Point(0,0));
		im.line((r.min.x,y0),(r.max.x,y0),0,0,0,grid,Point(0,0));
	}
	for(i=1;i<nh;i++)
		im.line((map(histx[i-1],-22.0,22.0,r.min.x,r.max.x),map(histz[i-1],0.0,52.0,r.max.y,r.min.y)),(map(histx[i],-22.0,22.0,r.min.x,r.max.x),map(histz[i],0.0,52.0,r.max.y,r.min.y)),0,0,1,live,Point(0,0));
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Lorenz chaos — t %.2f  x %.3f  y %.3f  z %.3f",t,y[0],y[1],y[2]));
	drawpar(im,0,"sigma",sigma,25.0);
	drawpar(im,1,"rho",rho,50.0);
	drawpar(im,2,"beta",beta,5.0);
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
timer(c:chan of int)
{
	for(;;){
		sys->sleep(25);
		c<-=1;
	}
}
