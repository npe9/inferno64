implement Videosynth;

# Nelson's Dream Machines chapter on video singles out Dan Sandin's
# Image Processor (1973) - a patchable analog rig of oscillators,
# colorizers and feedback loops that turned a video signal into
# something to play like an instrument, not just record. There's no
# real video signal here to patch (no camera, no analog feedback path),
# so this is a digital work-alike of the *idiom*, not the hardware: a
# waveform generator (three interfering sine terms standing in for a
# bank of oscillators) drives a colorizer (value -> hue, cycling over
# time, standing in for Sandin's colour-keying modules), and a software
# feedback loop blends each frame with the last so patterns trail and
# decay the way an analog video loop would rather than cutting cleanly
# frame to frame. Swapping "patches" (four built-in oscillator/colour
# parameter sets, cycled with a key) stands in for re-patching the real
# machine's cables.
#
# Deliberately chunky, low-resolution "pixels" (a small logical grid,
# each cell blown up to a solid square of real screen pixels) rather
# than a full-resolution field: it's both authentically period (video
# synths of this era ran at video-signal, not modern-display,
# resolution) and the reason the expensive part - the sine terms - only
# runs once per grid cell instead of once per screen pixel, which is
# what keeps this comfortably real-time under Limbo bytecode.
#
# Runs as a bare wmclient window (like computermovie.b/draw3ddemo.b),
# not a Tk app - there's nothing here a button would add over a key
# binding, and per [[inferno-rio-dream-machine-roadmap]]'s wm/toycpu.b
# entry, this Cocoa backend's synthetic-click delivery to Tk buttons is
# unreliable right now anyway; keyboard-only sidesteps it entirely.
#
# keys: c=cycle patch  f=toggle feedback  +/-=speed  r=reset  q/Esc=quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Videosynth: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

GRIDW: con 100;
GRIDH: con 70;
BLOCK: con 6;

Patch: adt {
	name:		string;
	fx, fy, fxy:	real;	# spatial frequencies
	sx, sy, sxy:	real;	# time-scroll speeds
	huespeed:	real;	# degrees/second of colour cycling
	radial:		int;	# true: fxy/sxy term uses distance from centre
};

patches := array[] of {
	Patch("Ripple", 0.15, 0.15, 0.10,  0.6,  0.6,  0.9, 20.0, 0),
	Patch("Weave",  0.35, -0.30, 0.25, 1.4, -1.1,  1.8, 45.0, 0),
	Patch("Storm",  0.60, 0.55, 0.50,  2.5, -2.2,  3.0, 90.0, 0),
	Patch("Pulse",  0.20, 0.20, 0.35,  0.8,  0.8, -2.0, 60.0, 1),
};

win: ref Window;
white: ref Image;
font: ref Font;
t := 0.0;
speed := 1.0;
patchidx := 0;
fbon := 1;
fbamount := 0.85;
prevbuf: array of real;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil){
		sys->fprint(sys->fildes(2), "videosynth: cannot load wmclient: %r\n");
		raise "fail:load";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "Video Synth", Wmclient->Appl);
	d := win.display;
	white = d.color(Draw->White);
	font = Font.open(d, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");

	prevbuf = array[GRIDW*GRIDH] of {* => 0.0};

	win.reshape(Rect((0, 0), (GRIDW*BLOCK, GRIDH*BLOCK+20)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			frame();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		dokey(k);
	<-ticks =>
		t += 0.033*speed;
		frame();
	}
}

dokey(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'c' or 'C' =>
		patchidx = (patchidx+1) % len patches;
	'f' or 'F' =>
		fbon = !fbon;
	'+' or '=' =>
		speed *= 1.25;
		if(speed > 6.0)
			speed = 6.0;
	'-' or '_' =>
		speed /= 1.25;
		if(speed < 0.05)
			speed = 0.05;
	'r' or 'R' =>
		t = 0.0;
		speed = 1.0;
		for(i := 0; i < len prevbuf; i++)
			prevbuf[i] = 0.0;
	}
}

# One interfering-sine-waves waveform per grid cell, -3..3 in principle
# (three unit sine terms summed), normalised to 0..1 by the caller.
wave(p: Patch, gx, gy: int): real
{
	fgx := real gx;
	fgy := real gy;
	a := math->sin(fgx*p.fx + t*p.sx);
	b := math->sin(fgy*p.fy + t*p.sy);
	c: real;
	if(p.radial){
		dx := fgx - real GRIDW/2.0;
		dy := fgy - real GRIDH/2.0;
		dist := math->sqrt(dx*dx + dy*dy);
		c = math->sin(dist*p.fxy + t*p.sxy);
	}else
		c = math->sin((fgx+fgy)*p.fxy + t*p.sxy);
	return a+b+c;
}

hsv2rgb(h, s, v: real): (int, int, int)
{
	if(s <= 0.0){
		g := int (v*255.0);
		return (g, g, g);
	}
	hh := math->fmod(h, 360.0);
	if(hh < 0.0)
		hh += 360.0;
	hh /= 60.0;
	i := int math->floor(hh);	# int(real) ROUNDS in Limbo, not truncates -
					# int(2.5) is 3, not 2 - caught this live via
					# a headless probe: it was sending wildly
					# out-of-range (negative, >255) byte values
					# into writepixels, which is why the very
					# first live GUI attempt rendered as a flat,
					# washed-out field instead of a plasma pattern.
	ff := hh - real i;
	p := v*(1.0-s);
	q := v*(1.0-(s*ff));
	tt := v*(1.0-(s*(1.0-ff)));
	r, g, b: real;
	case i {
	0 => (r,g,b) = (v, tt, p);
	1 => (r,g,b) = (q, v, p);
	2 => (r,g,b) = (p, v, tt);
	3 => (r,g,b) = (p, q, v);
	4 => (r,g,b) = (tt, p, v);
	* => (r,g,b) = (v, p, q);
	}
	return (clampbyte(r*255.0), clampbyte(g*255.0), clampbyte(b*255.0));
}

clampbyte(v: real): int
{
	iv := int v;
	if(iv < 0)
		return 0;
	if(iv > 255)
		return 255;
	return iv;
}

frame()
{
	img := win.image;
	if(img == nil)
		return;

	p := patches[patchidx];
	rowbytes := GRIDW*BLOCK*3;
	buf := array[rowbytes * GRIDH*BLOCK] of byte;

	curfb := 0.0;
	if(fbon)
		curfb = fbamount;

	for(gy := 0; gy < GRIDH; gy++){
		for(gx := 0; gx < GRIDW; gx++){
			raw := wave(p, gx, gy);
			nv := (raw+3.0)/6.0;
			idx := gy*GRIDW+gx;
			nv = curfb*prevbuf[idx] + (1.0-curfb)*nv;
			prevbuf[idx] = nv;

			hue := math->fmod(nv*300.0 + t*p.huespeed, 360.0);
			(r, g, b) := hsv2rgb(hue, 1.0, 0.35+0.65*nv);

			for(by := 0; by < BLOCK; by++){
				rowoff := (gy*BLOCK+by)*rowbytes + gx*BLOCK*3;
				for(bx := 0; bx < BLOCK; bx++){
					o := rowoff + bx*3;
					buf[o] = byte b;
					buf[o+1] = byte g;
					buf[o+2] = byte r;
				}
			}
		}
	}
	img.writepixels(Rect(img.r.min, img.r.min.add((GRIDW*BLOCK, GRIDH*BLOCK))), buf);

	fbtext := "off";
	if(fbon)
		fbtext = sys->sprint("%d%%", int (fbamount*100.0));
	if(font != nil)
		img.text(Point(img.r.min.x+8, img.r.min.y+GRIDH*BLOCK+14), white, Point(0,0), font,
			sys->sprint("patch=%s  feedback=%s  speed=%.2fx   c=patch f=feedback +/-=speed r=reset q=quit",
				p.name, fbtext, speed));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
