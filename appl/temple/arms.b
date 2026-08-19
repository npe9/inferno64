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
include "math.m";
	math: Math;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;

Arms: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
bg, fg, grid, live, accent, faint: ref Image;
y := array[] of {0.15, 0.18};
responsea := 0.45;
responseb := 0.40;
fatigue := 0.65;
grievance := 0.05;
t := 0.0;
paused := 0;
pointerready := 0;
w: ref Numerics->Workspace;
graph: ref Plotter;
phaseplotr, timeplotr: Rect;
tminshown, tmaxshown: real;
phasemax, timeymax: real;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	math = load Math Math->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || math == nil ||
			numerics == nil || plot == nil)
		raise "fail:arms: missing module";
	if(env != nil){
		env->clone();
		env->setenv("wmman", "danby-arms");
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Arms race", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	live = win.display.color(int 16r178f86ff);
	accent = win.display.color(int 16rb85c38ff);
	faint = win.display.color(int 16ra9aaa4ff);
	w = numerics->workspace(len y);
	graph = plot->new(win.image,font);
	graph.cmd("table history time a b -capacity 12000");
	graph.cmd("table vectors b a db da -capacity 64");
	graph.cmd("table nulla b a -capacity 40");
	graph.cmd("table nullb b a -capacity 40");
	graph.cmd("table initial b a -capacity 1");
	graph.cmd("table current b a -capacity 1");
	graph.cmd("table equilibrium b a -capacity 1");
	graph.cmd("table direction b a db da -capacity 1");
	graph.cmd("colour foreground 16r20272cff\n" +
		"colour grid 16rd6d0c4ff\n" +
		"colour live 16r178f86ff\n" +
		"colour accent 16rb85c38ff\n" +
		"colour faint 16ra9aaa4ff");
	reset();
	win.reshape(Rect((0,0),(900,650)));
	# Exact placement prevents WM's placement gestures from leaking into the
	# phase portrait or parameter controls.
	win.onscreen("place");
	pointerready = 2;
	win.startinput("kbd"::"ptr"::nil);
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		pointer(p);
		redraw();
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		' ' => paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused) step();
		}
	<-ticks =>
		if(!paused)
			for(i := 0; i < 4; i++)
				step();
		redraw();
	}
}

rhs(nil: real, q, d: array of real)
{
	d[0] = responsea*q[1]-fatigue*q[0]+grievance;
	d[1] = responseb*q[0]-fatigue*q[1]+grievance;
}

reset()
{
	y[0] = 0.15;
	y[1] = 0.18;
	t = 0.0;
	paused = 0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",t,y[0],y[1]));
	graph.cmd("initial clear");
	graph.cmd(sys->sprint("initial append %.17g %.17g",y[1],y[0]));
}

step()
{
	numerics->rk4(w,rhs,t,0.008,y);
	t += 0.008;
	if(y[0] < 0.0)
		y[0] = 0.0;
	if(y[1] < 0.0)
		y[1] = 0.0;
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",t,y[0],y[1]));
}

contains(r: Rect, p: Point): int
{
	return p.x >= r.min.x && p.x < r.max.x &&
		p.y >= r.min.y && p.y < r.max.y;
}

pointer(p: ref Draw->Pointer)
{
	# Do not interpret the button used by WM to place the new window as an
	# application drag.  Arm controls only after the first button-up event.
	if(pointerready < 2){
		# Consume the complete press/release gesture WM uses to place us.
		# A timeout is insufficient because interactive placement can last
		# arbitrarily long.
		if(pointerready == 0 && p.buttons != 0)
			pointerready = 1;
		else if(pointerready == 1 && p.buttons == 0)
			pointerready = 2;
		return;
	}
	if(!(p.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	if(p.xy.y >= r.max.y-52){
		wid := r.dx()/4;
		j := (p.xy.x-r.min.x)/wid;
		f := real(p.xy.x-(r.min.x+j*wid))/real(wid);
		if(f < 0.02) f = 0.02;
		if(f > 0.98) f = 0.98;
		if(j == 0) responsea = 1.5*f;
		if(j == 1) responseb = 1.5*f;
		if(j == 2) fatigue = 1.5*f;
		if(j >= 3) grievance = 0.5*f;
		restarttrace();
		return;
	}
	if(graph != nil){
		(bv,av,e) := graph.invert("phase",p.xy);
		if(e != nil)
			return;
		if(av < 0.0) av = 0.0;
		if(bv < 0.0) bv = 0.0;
		y[0] = av;
		y[1] = bv;
		restarttrace();
	}
}

restarttrace()
{
	t = 0.0;
	graph.cmd("history clear");
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",t,y[0],y[1]));
	graph.cmd("initial clear");
	graph.cmd(sys->sprint("initial append %.17g %.17g",y[1],y[0]));
}

vectorfield(r: Rect)
{
	graph.cmd("vectors clear");
	nx := 6;
	ny := 5;
	for(iy := 0; iy < ny; iy++)
		for(ix := 0; ix < nx; ix++){
			bv := phasemax*real(ix)/real(nx-1);
			av := phasemax*real(iy)/real(ny-1);
			q := array[] of {av,bv};
			d := array[2] of real;
			rhs(0.0,q,d);
			sx := d[1]*real(r.dx())/phasemax;
			sy := d[0]*real(r.dy())/phasemax;
			length := math->sqrt(sx*sx+sy*sy);
			if(length > 0.000001)
				graph.cmd(sys->sprint("vectors append %.17g %.17g %.17g %.17g",bv,av,d[1]*11.0/length,d[0]*11.0/length));
		}
}

nullclines()
{
	graph.cmd("nulla clear");
	graph.cmd("nullb clear");
	for(i := 0; i < 40; i++){
		bv := phasemax*real(i)/39.0;
		if(absr(fatigue) > 0.000001){
			av := (responsea*bv+grievance)/fatigue;
			if(av >= 0.0 && av <= phasemax) graph.cmd(sys->sprint("nulla append %.17g %.17g",bv,av));
		}
		if(absr(responseb) > 0.000001){
			av := (fatigue*bv-grievance)/responseb;
			if(av >= 0.0 && av <= phasemax) graph.cmd(sys->sprint("nullb append %.17g %.17g",bv,av));
		}
	}
}

drawphase(r: Rect)
{
	phasemax = domainmax();
	pr := Rect(r.min.add((42,28)),r.max.sub((10,32)));
	phaseplotr = pr;
	pcmd(sys->sprint("view phase %d %d %d %d",pr.min.x,pr.min.y,pr.max.x,pr.max.y));
	pcmd(sys->sprint("scale phase x 0 %.8g",phasemax));
	pcmd(sys->sprint("scale phase y 0 %.8g reverse",phasemax));
	pcmd("axis phase x B");
	pcmd("axis phase y A");
	vectorfield(pr);
	nullclines();
	graph.cmd("current clear");
	graph.cmd(sys->sprint("current append %.17g %.17g",y[1],y[0]));
	graph.cmd("direction clear");
	if(graph.rows("history") >= 2){
		i := graph.rows("history")-2;
		b0 := plotvalue("history",i,"b");
		a0 := plotvalue("history",i,"a");
		graph.cmd(sys->sprint("direction append %.17g %.17g %.17g %.17g",b0,a0,y[1]-b0,y[0]-a0));
	}
	graph.cmd("equilibrium clear");
	det := fatigue*fatigue-responsea*responseb;
	if(det > 0.000001){
		ea := grievance*(fatigue+responsea)/det;
		eb := grievance*(fatigue+responseb)/det;
		if(ea >= 0.0 && ea <= phasemax && eb >= 0.0 && eb <= phasemax)
			graph.cmd(sys->sprint("equilibrium append %.17g %.17g",eb,ea));
	}
	pcmd("vector phase vectors x b y a dx db dy da colour faint width 1");
	pcmd("line phase nulla x b y a colour accent width 1");
	pcmd("line phase nullb x b y a colour live width 1");
	pcmd("line phase history x b y a colour foreground width 2");
	pcmd("point phase initial x b y a colour faint radius 4");
	pcmd("point phase equilibrium x b y a colour accent radius 5");
	pcmd("point phase current x b y a colour foreground radius 5");
	pcmd("vector phase direction x b y a dx db dy da colour foreground width 2");
}

drawtime(r: Rect)
{
	pr := Rect(r.min.add((42,25)),r.max.sub((10,32)));
	timeplotr = pr;
	tmin := 0.0;
	if(graph.rows("history") > 0)
		tmin = plotvalue("history",0,"time");
	tmax := t;
	if(tmax < 10.0) tmax = 10.0;
	timeymax = domainmax();
	tminshown = tmin;
	tmaxshown = tmax;
	pcmd(sys->sprint("view time %d %d %d %d",pr.min.x,pr.min.y,pr.max.x,pr.max.y));
	pcmd(sys->sprint("scale time x %.8g %.8g",tmin,tmax));
	pcmd(sys->sprint("scale time y 0 %.8g reverse",timeymax));
	pcmd("axis time x time");
	pcmd("axis time y A,B");
	pcmd("line time history x time y a colour live width 2");
	pcmd("line time history x time y b colour accent width 2");
}

drawstate(im: ref Image, r: Rect)
{
	r = inset(r,12);
	im.text(r.min.add((0,14)),fg,Point(0,0),font,"dA/dt = rA B - f A + g");
	im.text(r.min.add((0,30)),fg,Point(0,0),font,"dB/dt = rB A - f B + g");
	statebar(im,Rect((r.min.x,r.min.y+42),(r.max.x,r.min.y+62)),
		"A",y[0],live,phasemax);
	statebar(im,Rect((r.min.x,r.min.y+82),(r.max.x,r.min.y+102)),
		"B",y[1],accent,phasemax);
	det := fatigue*fatigue-responsea*responseb;
	lambda := -fatigue;
	if(responsea*responseb >= 0.0)
		lambda += math->sqrt(responsea*responseb);
	trend := "growth";
	if(lambda < 0.0)
		trend = "decay";
	if(det > 0.000001){
		ea := grievance*(fatigue+responsea)/det;
		eb := grievance*(fatigue+responseb)/det;
		im.text((r.min.x,r.min.y+132),faint,Point(0,0),font,
			sys->sprint("equilibrium  A %.3f   B %.3f",ea,eb));
	}
	im.text((r.min.x,r.min.y+150),fg,Point(0,0),font,
		sys->sprint("dominant rate  λ = %.3f  (%s)",lambda,trend));
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	graph.image = im;
	pcmd("clear");
	im.draw(im.r,bg,nil,Point(0,0));
	content := Rect(im.r.min.add((8,27)),im.r.max.sub((8,55)));
	(top,bottom) := splity(content,0.63);
	(phase,state) := splitx(top,0.66);
	drawphase(inset(phase,4));
	drawstate(im,inset(state,4));
	drawtime(inset(bottom,4));
	graph.draw();
	drawannotations(im);
	det := fatigue*fatigue-responsea*responseb;
	status := "stable equilibrium";
	if(det <= 0.0)
		status = "unstable escalation";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("Arms race   %s   t = %.2f",status,t));
	drawpar(im,0,"rA response A",responsea,1.5);
	drawpar(im,1,"rB response B",responseb,1.5);
	drawpar(im,2,"f fatigue",fatigue,1.5);
	drawpar(im,3,"g grievance",grievance,0.5);
	im.flush(Draw->Flushnow);
}

statebar(im: ref Image, r: Rect, name: string, value: real,
		colour: ref Image, maximum: real)
{
	im.text((r.min.x,r.min.y+13),fg,Point(0,0),font,
		sys->sprint("%s  %.3f",name,value));
	x0 := r.min.x+58;
	x1 := r.max.x;
	im.line((x0,r.min.y+9),(x1,r.min.y+9),0,0,1,grid,Point(0,0));
	f := value/maximum;
	if(f < 0.0) f = 0.0;
	if(f > 1.0) f = 1.0;
	im.line((x0,r.min.y+9),(x0+int(f*real(x1-x0)),r.min.y+9),
		0,0,4,colour,Point(0,0));
	im.text((x1-font.width(sys->sprint("%.3g",maximum)),r.min.y+22),
		faint,Point(0,0),font,sys->sprint("%.3g",maximum));
}

domainmax(): real
{
	m := 0.25;
	for(i := 0; i < graph.rows("history"); i++){
		a := plotvalue("history",i,"a");
		b := plotvalue("history",i,"b");
		if(a > m) m = a;
		if(b > m) m = b;
	}
	det := fatigue*fatigue-responsea*responseb;
	if(det > 0.000001){
		ea := grievance*(fatigue+responsea)/det;
		eb := grievance*(fatigue+responseb)/det;
		if(ea > m) m = ea;
		if(eb > m) m = eb;
	}
	m *= 1.15;
	# Explicit 1/2/5 ranges keep axes stable and their upper bound legible.
	p := math->pow(10.0,math->floor(math->log10(m)));
	f := m/p;
	if(f <= 1.0) return p;
	if(f <= 2.0) return 2.0*p;
	if(f <= 5.0) return 5.0*p;
	return 10.0*p;
}

plotpoint(r: Rect, x, y, xmin, xmax, ymin, ymax: real): Point
{
	px := r.min.x+int((x-xmin)*real(r.dx())/(xmax-xmin));
	py := r.max.y-int((y-ymin)*real(r.dy())/(ymax-ymin));
	return (px,py);
}

drawannotations(im: ref Image)
{
	# Direct labels replace legends and make each line explain itself.
	bv := 0.72*phasemax;
	if(absr(fatigue) > 0.000001){
		av := (responsea*bv+grievance)/fatigue;
		if(av >= 0.0 && av <= phasemax){
			p := plotpoint(phaseplotr,bv,av,0.0,phasemax,0.0,phasemax);
			im.text(p.add((5,-4)),accent,Point(0,0),font,"dA/dt = 0");
		}
	}
	if(absr(responseb) > 0.000001){
		av := (fatigue*bv-grievance)/responseb;
		if(av >= 0.0 && av <= phasemax){
			p := plotpoint(phaseplotr,bv,av,0.0,phasemax,0.0,phasemax);
			im.text(p.add((5,-4)),live,Point(0,0),font,"dB/dt = 0");
		}
	}
	det := fatigue*fatigue-responsea*responseb;
	if(det > 0.000001){
		ea := grievance*(fatigue+responsea)/det;
		eb := grievance*(fatigue+responseb)/det;
		if(ea >= 0.0 && ea <= phasemax && eb >= 0.0 && eb <= phasemax){
			p := plotpoint(phaseplotr,eb,ea,0.0,phasemax,0.0,phasemax);
			im.text(p.add((8,-8)),fg,Point(0,0),font,"equilibrium");
		}
	}
	pa := plotpoint(timeplotr,t,y[0],tminshown,tmaxshown,0.0,timeymax);
	pb := plotpoint(timeplotr,t,y[1],tminshown,tmaxshown,0.0,timeymax);
	im.text(pa.add((-30,-5)),live,Point(0,0),font,"A(t)");
	im.text(pb.add((-30,12)),accent,Point(0,0),font,"B(t)");
}

pcmd(s: string)
{
	e := graph.cmd(s);
	if(e != nil)
		sys->fprint(sys->fildes(2),"arms: plot command %q: %s\n",s,e);
}

plotvalue(table: string, row: int, column: string): real
{
	(value, error) := graph.value(table,row,column);
	if(error != nil)
		sys->fprint(sys->fildes(2),"arms: %s\n",error);
	return value;
}

inset(r: Rect, n: int): Rect
{
	return Rect(r.min.add((n,n)),r.max.sub((n,n)));
}

splitx(r: Rect, fraction: real): (Rect, Rect)
{
	x := r.min.x+int(real(r.dx())*fraction);
	return (Rect(r.min,(x,r.max.y)),Rect((x,r.min.y),r.max));
}

splity(r: Rect, fraction: real): (Rect, Rect)
{
	yv := r.min.y+int(real(r.dy())*fraction);
	return (Rect(r.min,(r.max.x,yv)),Rect((r.min.x,yv),r.max));
}

weaponstack(im: ref Image, r: Rect, value: real, colour: ref Image, label: string)
{
	if(value < 0.0)
		value = 0.0;
	n := int(value/0.025);
	if(n > 60)
		n = 60;
	im.text(r.min.add((4,14)),fg,Point(0,0),font,
		sys->sprint("%s %.3f",label,value));
	for(i := 0; i < n; i++){
		row := i/5;
		x := r.min.x+(i%5)*r.dx()/5+3;
		yv := r.max.y-row*15-6;
		if(yv < r.min.y+22)
			break;
		im.draw(Rect((x,yv-3),(x+r.dx()/5-7,yv+4)),colour,nil,Point(0,0));
	}
}

drawpar(im: ref Image, j: int, name: string, value, maximum: real)
{
	wid := im.r.dx()/4;
	x := im.r.min.x+j*wid;
	yv := im.r.max.y-39;
	im.line((x+4,yv),(x+wid-6,yv),0,0,2,grid,Point(0,0));
	k := x+4+int(value/maximum*real(wid-10));
	im.ellipse((k,yv),4,4,0,accent,Point(0,0));
	im.text((x+4,im.r.max.y-17),fg,Point(0,0),font,
		sys->sprint("%s %.3g",name,value));
}

absr(v: real): real
{
	if(v < 0.0)
		return -v;
	return v;
}

timer(c: chan of int)
{
	for(;;){
		sys->sleep(25);
		c <-= 1;
	}
}
