implement Ecology;
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
include "danby/twospecies.m";
Ecology: module { init: fn(ctxt: ref Draw->Context, argv: list of string);
 };
win: ref Window;
font: ref Font;
bg, fg, grid, live, accent: ref Image;
y := array[] of {0.55, 0.22};
birth := 1.5;
predation := 2.0;
death := 0.75;
t := 0.0;
paused := 0;
w: ref Numerics->Workspace;
graph: ref Plotter;
modelmodule: Twospecies;
model: ref Twospecies->Model;
modellabels: array of string;
modelranges: array of real;
modeltitle := "Predator and prey";
manpage := "danby-ecology";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil || plot == nil)
		raise "fail:Ecology: missing module";
	if(tl argv != nil){
		modelpath := hd tl argv;
		modelmodule = load Twospecies modelpath;
		if(modelmodule == nil)
			raise "fail:Ecology: cannot load " + modelpath;
		model = modelmodule->new();
		modellabels = modelmodule->parameterlabels();
		modelranges = modelmodule->parameterranges();
		modeltitle = modelmodule->title();
		if(tl tl argv != nil)
			manpage = hd tl tl argv;
	}else{
		modelmodule = load Twospecies "/dis/danby/ecology.dis";
		if(modelmodule == nil)
			raise "fail:Ecology: cannot load ecology model";
		model = modelmodule->new();
		modellabels = modelmodule->parameterlabels();
		modelranges = modelmodule->parameterranges();
		modeltitle = modelmodule->title();
	}
	if(env != nil){ env->clone();
	 env->setenv("wmman", manpage);
	 }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, modeltitle, Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg=win.display.color(int 16rf4f0e7ff);
	 fg=win.display.color(int 16r20272cff);
	grid=win.display.color(int 16rd6d0c4ff);
	 live=win.display.color(int 16r178f86ff);
	accent=win.display.color(int 16rb85c38ff);
	w=numerics->workspace(len y);
	graph=plot->new(win.image,font);
	graph.cmd("table history time prey predators -capacity 12000");
	graph.cmd("table equilibrium prey predators -capacity 1");
	graph.cmd("table current prey predators -capacity 1");
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
rhs(rhsTime: real, q, d: array of real)
{
	if(model != nil){
		modelmodule->evaluate(model,rhsTime,q,d);
		return;
	}
	d[0]=birth*q[0]-predation*q[0]*q[1];
	d[1]=q[0]*q[1]-death*q[1];
}
reset()
{
	y[0]=0.55;
	y[1]=0.22;
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
		nparameter := 3;
		if(model != nil)
			nparameter = len model.parameter;
		wid:=r.dx()/nparameter;
		j:=(p.xy.x-r.min.x)/wid;
		f:=real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(f<0.02)f=0.02;
		if(model != nil){
			if(j >= len model.parameter)
				j = len model.parameter-1;
			model.parameter[j] = modelranges[j]*f;
		}
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
	content:=Rect(im.r.min.add((45,35)),im.r.max.sub((18,58)));
	mid:=content.min.x+content.dx()/2;
	phase:=Rect(content.min,(mid-24,content.max.y));
	timeplot:=Rect((mid+30,content.min.y),content.max);
	maximum:=1.5;
	if(y[0]*1.15>maximum)
		maximum=y[0]*1.15;
	if(y[1]*1.15>maximum)
		maximum=y[1]*1.15;
	graph.image=im;
	graph.cmd("clear");
	graph.cmd(sys->sprint("view phase %d %d %d %d",phase.min.x,phase.min.y,phase.max.x,phase.max.y));
	graph.cmd(sys->sprint("scale phase x 0 %.8g",maximum));
	graph.cmd(sys->sprint("scale phase y 0 %.8g reverse",maximum));
	graph.cmd("axis phase x prey");
	graph.cmd("axis phase y predators");
	graph.cmd("equilibrium clear");
	equilibriumprey := death;
	equilibriumpredators := birth/predation;
	if(model != nil)
		(equilibriumprey,equilibriumpredators) =
			modelmodule->fixedpoint(model);
	graph.cmd(sys->sprint("equilibrium append %.17g %.17g",
		equilibriumprey,equilibriumpredators));
	graph.cmd("current clear");
	graph.cmd(sys->sprint("current append %.17g %.17g",y[0],y[1]));
	graph.cmd("line phase history x prey y predators colour foreground width 2");
	graph.cmd("point phase equilibrium x prey y predators colour accent radius 5");
	graph.cmd("point phase current x prey y predators colour live radius 4");
	tmax:=t;
	if(tmax<10.0)
		tmax=10.0;
	graph.cmd(sys->sprint("view time %d %d %d %d",timeplot.min.x,timeplot.min.y,timeplot.max.x,timeplot.max.y));
	graph.cmd(sys->sprint("scale time x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale time y 0 %.8g reverse",maximum));
	graph.cmd("axis time x time");
	graph.cmd("axis time y population");
	graph.cmd("line time history x time y prey colour live width 2");
	graph.cmd("line time history x time y predators colour accent width 2");
	graph.draw();
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   equilibrium %.3g, %.3g",
			modeltitle,equilibriumprey,equilibriumpredators));
	if(model != nil){
		for(j:=0; j<len model.parameter; j++)
			drawpar(im,j,len model.parameter,modellabels[j],
				model.parameter[j],modelranges[j]);
	}else{
		drawpar(im,0,3,"prey birth",birth,3.0);
		drawpar(im,1,3,"predation",predation,4.0);
		drawpar(im,2,3,"predator death",death,3.0);
	}
	im.flush(Draw->Flushnow);
}
drawpar(im: ref Image,j,nparameter:int,name:string,v,max:real)
{
	wid:=im.r.dx()/nparameter;
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
