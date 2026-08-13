implement Vaccination;
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
 vaccinationmodel: Populationmodel;
Vaccination: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.792,0.01,0.0,0.198};
contact := 2.2;
recovery := 0.55;
coverage := 0.20;
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
	vaccinationmodel = load Populationmodel "/dis/danby/vaccination.dis";
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil ||
			plot == nil || vaccinationmodel == nil)
		raise "fail:vaccination: missing module";
	model = vaccinationmodel->new();
	if(env != nil){ env->clone();
	 env->setenv("wmman", "danby-vaccination");
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "SIR vaccination", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	graph=plot->new(win.image,font);
	graph.cmd("table history time S I R V -capacity 12000");
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
rhs(rhsTime: real, q, d: array of real)
{
	vaccinationmodel->evaluate(model,rhsTime,q,d);
}
reset()
{
	y[0]=0.792;
	y[1]=0.01;
	y[2]=0.0;
	y[3]=coverage*0.99;
	y[0]=(1.0-coverage)*0.99;
	model.parameter[0] = contact;
	model.parameter[1] = recovery;
	model.parameter[2] = coverage;
	t=0.0;
	paused=0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g %.17g",t,y[0],y[1],y[2],y[3]));
}
step()
{
	numerics->rk4(w, rhs, t, 0.008, y);
	 t+=0.008;
	for(i:=0;i<len y;i++)if(y[i]<0.0)y[i]=0.0;
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g %.17g",t,y[0],y[1],y[2],y[3]));
}
pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image==nil)return;
	r:=win.image.r;
	if(p.xy.y>r.max.y-52){
		wid:=r.dx()/3;
		j:=(p.xy.x-r.min.x)/wid;
		f:=real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(j==0)contact=4.0*f;
		if(j==1)recovery=4.0*f;
		if(j>=2){
			coverage=0.98*f;
			total:=y[0]+y[3];
			y[3]=coverage*total;
			y[0]=(1.0-coverage)*total;
		}
		if(contact<0.02)contact=0.02;
		if(recovery<0.02)recovery=0.02;
		model.parameter[0] = contact;
		model.parameter[1] = recovery;
		model.parameter[2] = coverage;
	}else{
		y[1]=real(r.max.y-58-p.xy.y)/real(r.dy()-93);
		if(y[1]<0.0)y[1]=0.0;
		if(y[1]>1.0)y[1]=1.0;
		y[0]=(1.0-coverage)*(1.0-y[1]);
		y[2]=0.0;
		y[3]=coverage*(1.0-y[1]);
	}
	t=0.0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g %.17g",t,y[0],y[1],y[2],y[3]));
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
	graph.cmd(sys->sprint("scale main x 0 %.8g",tmax));
	graph.cmd("scale main y 0 1 reverse");
	graph.cmd("axis main x time");
	graph.cmd("axis main y fraction");
	graph.cmd("line main history x time y S colour live width 2");
	graph.cmd("line main history x time y I colour accent width 2");
	graph.cmd("line main history x time y R colour foreground width 2");
	graph.cmd("line main history x time y V colour grid width 2");
	graph.draw();
	x:=r.max.x-24;
	im.text((x,map(y[0],0.0,1.0,r.max.y,r.min.y)),live,(0,0),font,"S");
	im.text((x,map(y[1],0.0,1.0,r.max.y,r.min.y)),accent,(0,0),font,"I");
	im.text((x,map(y[2],0.0,1.0,r.max.y,r.min.y)),fg,(0,0),font,"R");
	im.text((x,map(y[3],0.0,1.0,r.max.y,r.min.y)),fg,(0,0),font,"V");
	r0:=contact/recovery;
	critical:=1.0-1.0/r0;
	total:=y[0]+y[1]+y[2]+y[3];
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,sys->sprint("Vaccination   R0 %.3g   critical coverage %.3f   total %.6f",r0,critical,total));
	drawpar(im,0,"contact",contact,4.0);
	drawpar(im,1,"recovery",recovery,4.0);
	drawpar(im,2,"coverage",coverage,0.98);
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
