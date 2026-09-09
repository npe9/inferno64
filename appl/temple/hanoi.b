implement Hanoi;

# TempleOS Demo/Graphics/Hanoi.HC — animated Towers of Hanoi.
#
# MoveDisks is the whole program: the classic three-line recursion, with
# the animation of the move sitting in the middle of it.  Each call
# clears the document and prints
#
#	"$$CM+BY,0,0$$Disk:%d from %d to %d\n",TopDisk(src_pole),
#		src_pole,dst_pole
#
# so the readout at the top left is the recursion talking, and the disk
# numbers it names run large-to-small as the stack unwinds.  MySleep is
# Sleep(3) a pixel and throws if a key has been hit, which is how a run
# is abandoned; two Beeps and a PressAKey end it.
#
# The disks take their colours from gr_rainbow_10 (Adam/Gr/GrPalette.HC),
# which is BLACK, BROWN, RED, LTRED, YELLOW, GREEN, BLUE, PURPLE, LTGRAY,
# WHITE — and disk 0 is the smallest, so the little one on top is black.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tone.m";
	tone: Tone;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "grpalette.m";
	grpal: Grpalette;

Hanoi: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

DISKS: con 6;
PED: con 20;			# PEDESTAL_HEIGHT
DH: con 7;			# DISK_HEIGHT
DW: con 5;			# DISK_UNIT_WIDTH
FH := 8;			# the font's line height, set when the font opens
A4ONA: con 60;			# Ona2Freq: ona 60 is 440Hz

# gr_rainbow_10, in TempleOS colour indices
rainbow10 := array[] of {0, 6, 4, 12, 14, 2, 1, 5, 7, 15};

win: ref Window;
font: ref Font;
ink: array of ref Image;
have_tone := 0;
msg := "";
poles_x: array of int;
disks_x, disks_y, disks_pole: array of int;
quitreq := 0;
moving := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Hanoi", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	if(font != nil){
		FH = font.height;
	}
	math = load Math Math->PATH;
	tone = load Tone Tone->PATH;
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	# the exact TempleOS 16-colour palette, index = TempleOS colour
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	poles_x = array[3] of int;
	disks_x = array[DISKS] of int;
	disks_y = array[DISKS] of int;
	disks_pole = array[DISKS] of int;
	win.reshape(Rect((0, 0), (640, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	reset();
	redraw();
	spawn animate();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q'){
			quitreq = 1;
			exit;
		}
		if(k == '\n' || k == 'r' || k == 'R'){
			if(!moving){
				reset();
				spawn animate();
			}
		}
	}
}

reset()
{
	img := win.image;
	w := 640;
	if(img != nil)
		w = img.r.dx();
	for(i := 0; i < 3; i++)
		poles_x[i] = (1+i)*w/4;
	for(i = 0; i < DISKS; i++)
		disks_pole[i] = 0;
	setrest();
}

setrest()
{
	img := win.image;
	h := 400;
	if(img != nil)
		h = img.r.dy();
	for(i := 0; i < DISKS; i++){
		disks_x[i] = poles_x[disks_pole[i]];
		disks_y[i] = h - PED - (DH+1)/2 - 1 - (DH+1)*posinstk(disks_pole[i], i);
	}
}

posinstk(pole, disk: int): int
{
	res := 0;
	for(i := DISKS-1; i > disk; i--)
		if(disks_pole[i] == pole)
			res++;
	return res;
}

topdisk(pole: int): int
{
	for(i := 0; i < DISKS; i++)
		if(disks_pole[i] == pole)
			return i;
	return -1;
}

other(a, b: int): int
{
	return 3 - a - b;
}

mysleep()
{
	if(quitreq)
		return;
	sys->sleep(3);
	redraw();
}

movedisks(src, dst, num: int)
{
	if(quitreq)
		return;
	if(num > 1)
		movedisks(src, other(src, dst), num-1);
	top := topdisk(src);
	if(top < 0)
		return;
	# DocClear, then "$CM+BY,0,0$Disk:%d from %d to %d\n"
	msg = sys->sprint("Disk:%d from %d to %d", top, src, dst);
	img := win.image;
	h := 400;
	if(img != nil)
		h = img.r.dy();
	top_y := h - PED - (DH+1)/2 - (DH+1)*(DISKS+2);
	for(y := disks_y[top]; y > top_y; y--){
		disks_y[top] = y;
		mysleep();
	}
	if(src < dst)
		for(x := poles_x[src]; x <= poles_x[dst]; x++){
			disks_x[top] = x;
			mysleep();
		}
	else
		for(x = poles_x[src]; x >= poles_x[dst]; x--){
			disks_x[top] = x;
			mysleep();
		}
	disks_pole[top] = dst;
	dest_y := h - PED - (DH+1)/2 - 1 - (DH+1)*posinstk(dst, top);
	for(y = disks_y[top]; y < dest_y; y++){
		disks_y[top] = y;
		mysleep();
	}
	setrest();
	redraw();
	if(num > 1)
		movedisks(other(src, dst), dst, num-1);
}

animate()
{
	moving = 1;
	sys->sleep(400);
	movedisks(0, 2, DISKS);
	if(!quitreq){
		spawn beeps(2);		# Beep; Beep;
		msg = "";		# DocClear, then PressAKey
		redraw();
	}
	moving = 0;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	o := img.r.min;
	h := img.r.dy();
	for(i := 0; i < 3; i++)
		poles_x[i] = (1+i)*img.r.dx()/4;
	# pedestal
	img.draw(Rect((o.x+poles_x[0]-50, o.y+h-PED),
		(o.x+poles_x[2]+50, o.y+h-PED+PED-FH)), ink[0], nil, Point(0, 0));
	img.draw(Rect((o.x+poles_x[0]-49, o.y+h-PED+1),
		(o.x+poles_x[2]+49, o.y+h-PED+1+PED-FH-2)), ink[8], nil, Point(0, 0));
	for(i = 0; i < 3; i++){
		img.draw(Rect((o.x+poles_x[i]-3, o.y+h-PED-(DISKS+1)*(DH+1)),
			(o.x+poles_x[i]+4, o.y+h-PED)), ink[0], nil, Point(0, 0));
		img.draw(Rect((o.x+poles_x[i]-2, o.y+h-PED+1-(DISKS+1)*(DH+1)),
			(o.x+poles_x[i]+3, o.y+h-PED)), ink[14], nil, Point(0, 0));
	}
	for(i = 0; i < DISKS; i++){
		hw := (i+1)*DW;
		img.draw(Rect((o.x+disks_x[i]-hw, o.y+disks_y[i]-DH/2),
			(o.x+disks_x[i]+hw+1, o.y+disks_y[i]+DH/2)), ink[0], nil, Point(0, 0));
		img.draw(Rect((o.x+disks_x[i]-hw+1, o.y+disks_y[i]-DH/2+1),
			(o.x+disks_x[i]+hw, o.y+disks_y[i]+DH/2-1)),
			ink[rainbow10[i]], nil, Point(0, 0));
	}
	if(font != nil && msg != "")
		img.text(o, ink[0], Point(0, 0), font, msg);
	img.flush(Draw->Flushnow);
}

# Beep: Snd(62) for 500ms then silence for 200ms, n times.  Spawned, so
# a fanfare does not freeze the window the way the original's does.
beeps(n: int)
{
	if(!have_tone)
		return;
	for(i := 0; i < n; i++){
		tone->beep(onafreq(62), 500);
		sys->sleep(700);
	}
}

onafreq(ona: int): int
{
	if(math == nil)
		return 494;
	f := int (440.0 * math->pow(2.0, real (ona - A4ONA) / 12.0) + 0.5);
	if(f < 1)
		f = 1;
	return f;
}
