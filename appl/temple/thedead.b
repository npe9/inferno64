implement Thedead;

# TempleOS Demo/Games/TheDead.HC — side shooter
# up/down move  space=fire (hold)  Enter=restart  q=quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

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
font: ref Font;
ink: array of ref Image;
sprites, masks: array of ref Image;
px, py: int;
bin, bout: int;
bx, by: array of int;
din, dout: int;
gx, gy: array of int;
gdead: array of int;
gunheld := 0;
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
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[6] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Red);
	ink[2] = d.color(Draw->Green);
	ink[3] = d.color(Draw->White);
	ink[4] = d.color(Draw->Yellow);
	ink[5] = d.color(int 16r222222FF);
	sprites = array[4] of ref Image;
	masks = array[4] of ref Image;
	for(i := 1; i <= 3; i++){
		sprites[i] = d.open(sys->sprint("/icons/temple/thedead_%d.bit", i));
		masks[i] = d.open(sys->sprint("/icons/temple/thedead_%d.mask", i));
		if(sprites[i] == nil || masks[i] == nil){
			sys->fprint(sys->fildes(2), "thedead: cannot load sprite %d\n", i);
			raise "fail:sprite";
		}
	}

	bx = array[BNUM] of int;
	by = array[BNUM] of int;
	gx = array[DNUM] of int;
	gy = array[DNUM] of int;
	gdead = array[DNUM] of int;
	reset();
	if(have_tone)
		spawn songloop();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	steps := chan of int;
	frames := chan of int;
	spawn timer(steps, 10);
	spawn timer(frames, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	<-steps =>
		step();
	<-frames =>
		redraw();
	}
}

reset()
{
	px = 0;
	py = 240;
	bin = bout = 0;
	din = dout = 0;
	gunheld = 0;
	frame = 0;
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
		gunheld = 1;
	Keyboard->Up or 'w' or 'W' =>
		py -= 10;
		if(py < 0) py = 0;
	Keyboard->Down or 's' or 'S' =>
		py += 10;
		if(py > 450) py = 450;
	Keyboard->Keyup | ' ' or
	Keyboard->Keyup | (Keyboard->Right & 16r7ff) =>
		gunheld = 0;
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
	# move bullets
	i := bout;
	while(i != bin){
		j := i & (BNUM-1);
		bx[j] += 5;
		if(bx[j] > w)
			bout++;
		else{
			# HolyC uses the authored zombie's 40x38 bounding box.
			bi := dout;
			while(bi != din){
				bj := bi++ & (DNUM-1);
				if(gy[bj] <= by[j] && by[j] <= gy[bj]+38 &&
				   gx[bj] <= bx[j] && bx[j] <= gx[bj]+40)
					gdead[bj] = 1;
			}
		}
		i++;
	}
	if(gunheld){
		j := bin & (BNUM-1);
		bx[j] = px + 32;
		by[j] = py + 14;
		bin++;
	}

	# The dead advance one pixel on one out of every four 10ms passes.
	if(frame % 4 == 0){
		i = dout;
		while(i != din){
			j := i++ & (DNUM-1);
			gx[j]--;
			if(gx[j] < 25)
				dout++;
		}
	}
	# One new zombie every 150 passes.
	if(frame % 150 == 0){
		j := din & (DNUM-1);
		gx[j] = w - 30;
		gy[j] = rn(h - 50) + 25;
		gdead[j] = 0;
		din++;
	}
	frame++;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[3], nil, Point(0, 0));
	# player
	drawsprite(img, 1, o.x+px, o.y+py);
	# bullets
	i := bout;
	while(i != bin){
		j := i & (BNUM-1);
		img.line(Point(o.x+bx[j], o.y+by[j]), Point(o.x+bx[j]-2, o.y+by[j]),
			0, 0, 0, ink[0], Point(0, 0));
		i++;
	}
	# bad guys
	i = dout;
	while(i != din){
		j := i & (DNUM-1);
		if(!gdead[j]){
			si := 3;
			if(gx[j]%10 > 4)
				si = 2;
			drawsprite(img, si, o.x+gx[j], o.y+gy[j]);
		}
		i++;
	}
	img.text(Point(o.x, o.y), ink[0], Point(0, 0), font,
		"If you aspire to making games,");
	img.text(Point(o.x, o.y+16), ink[0], Point(0, 0), font,
		"you must learn to make-up rules.");
	img.flush(Draw->Flushnow);
}

drawsprite(img: ref Image, n, x, y: int)
{
	r := sprites[n].r;
	p := Point(x+r.min.x, y+r.min.y);
	img.draw(Rect(p, (p.x+r.dx(), p.y+r.dy())), sprites[n], masks[n], r.min);
}

songloop()
{
	for(;;)
		tone->play("5qDqDsDCDC4etB5C4B5qCqCqCqCqDqDsDCDC4etB5C4B5qCqCqCqCqCq" +
			"CsCCCCetCCBeBBeBBqBqBqCqCsCCCCetCCBeBBeBBqBqB");
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
