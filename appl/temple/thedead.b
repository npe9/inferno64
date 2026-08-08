implement Thedead;

# TempleOS Demo/Games/TheDead.HC — side shooter
# GAP: no sprites — stick figures; no background song (optional tone)
# up/down move  space=fire (hold)  Enter=restart  q=quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Thedead: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

BNUM: con 32;
DNUM: con 32;

win: ref Window;
ink: array of ref Image;
px, py: int;
bin, bout: int;
bx, by: array of int;
din, dout: int;
gx, gy: array of int;
gdead: array of int;
gun_until := 0;
move_until := 0;
kup := 0;
kdn := 0;
have_tone := 0;
frame := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS TheDead", Wmclient->Appl);
	d := win.display;
	ink = array[6] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Red);
	ink[2] = d.color(Draw->Green);
	ink[3] = d.color(Draw->White);
	ink[4] = d.color(Draw->Yellow);
	ink[5] = d.color(int 16r222222FF);

	bx = array[BNUM] of int;
	by = array[BNUM] of int;
	gx = array[DNUM] of int;
	gy = array[DNUM] of int;
	gdead = array[DNUM] of int;
	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	<-ticks =>
		step();
		redraw();
	}
}

reset()
{
	px = 40;
	py = 240;
	bin = bout = 0;
	din = dout = 0;
	gun_until = 0;
	move_until = 0;
	kup = kdn = 0;
	for(i := 0; i < DNUM; i++)
		gdead[i] = 1;
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'\n' =>
		reset();
	' ' or Keyboard->Right =>
		gun_until = sys->millisec() + 200;
	Keyboard->Up or 'w' or 'W' =>
		kup = 1; kdn = 0;
		move_until = sys->millisec() + 200;
	Keyboard->Down or 's' or 'S' =>
		kdn = 1; kup = 0;
		move_until = sys->millisec() + 200;
	}
}

step()
{
	img := win.image;
	h := 480;
	w := 640;
	if(img != nil){
		h = img.r.dy();
		w = img.r.dx();
	}
	now := sys->millisec();
	if(now > move_until)
		kup = kdn = 0;
	if(kup)
		py -= 8;
	if(kdn)
		py += 8;
	if(py < 20) py = 20;
	if(py > h-20) py = h-20;

	# fire while space linger (GAP: no true key-up)
	if(now < gun_until && (bin - bout) < BNUM-1){
		j := bin & (BNUM-1);
		bx[j] = px + 20;
		by[j] = py;
		bin++;
		if(have_tone)
			tone->beep(60, 20);
	}

	# move bullets
	i := bout;
	while(i != bin){
		j := i & (BNUM-1);
		bx[j] += 12;
		if(bx[j] > w)
			bout++;
		i++;
	}

	# spawn dead
	frame++;
	if(frame % 15 == 0 && (din - dout) < DNUM-1){
		j := din & (DNUM-1);
		gx[j] = w - 10;
		gy[j] = 20 + rn(h - 40);
		gdead[j] = 0;
		din++;
	}

	# move / collide
	i = dout;
	while(i != din){
		j := i & (DNUM-1);
		if(!gdead[j]){
			gx[j] -= 3;
			if(gx[j] < 0){
				gdead[j] = 1;
				dout++;
			}else{
				# bullet hit
				bi := bout;
				while(bi != bin){
					bj := bi & (BNUM-1);
					if(abs(bx[bj]-gx[j]) < 12 && abs(by[bj]-gy[j]) < 16){
						gdead[j] = 1;
						if(have_tone)
							tone->beep(40, 50);
						break;
					}
					bi++;
				}
			}
		}
		i++;
	}
	# compact fifo fronts
	while(bout != bin && bx[bout&(BNUM-1)] > w)
		bout++;
	while(dout != din && gdead[dout&(DNUM-1)])
		dout++;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[5], nil, Point(0, 0));
	# player
	drawdude(img, o.x+px, o.y+py, ink[2]);
	# bullets
	i := bout;
	while(i != bin){
		j := i & (BNUM-1);
		img.line(Point(o.x+bx[j], o.y+by[j]), Point(o.x+bx[j]-4, o.y+by[j]),
			0, 0, 0, ink[4], Point(0, 0));
		i++;
	}
	# bad guys
	i = dout;
	while(i != din){
		j := i & (DNUM-1);
		if(!gdead[j])
			drawdude(img, o.x+gx[j], o.y+gy[j], ink[1]);
		i++;
	}
	img.flush(Draw->Flushnow);
}

drawdude(img: ref Image, x, y: int, col: ref Image)
{
	img.fillellipse(Point(x, y-8), 4, 4, col, Point(0, 0));
	img.line(Point(x, y-4), Point(x, y+8), 0, 0, 0, col, Point(0, 0));
	img.line(Point(x-6, y), Point(x+6, y), 0, 0, 0, col, Point(0, 0));
	img.line(Point(x, y+8), Point(x-5, y+16), 0, 0, 0, col, Point(0, 0));
	img.line(Point(x, y+8), Point(x+5, y+16), 0, 0, 0, col, Point(0, 0));
}

abs(a: int): int
{
	if(a < 0) return -a;
	return a;
}

rn(n: int): int
{
	if(n <= 0) return 0;
	if(rand == nil) return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
