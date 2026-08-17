implement Pdelab;

# Interactive finite-difference PDE demonstrations.
# 1 heat, 2 wave, 3 Gray-Scott; draw with button 1; r reset; space pause.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "pde.m";
	pde: Pde;
	Field: import pde;

Pdelab: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

NX: con 96;
NY: con 72;

win: ref Window;
a, b: ref Field;
pal: array of ref Image;
font: ref Font;
mode := 1;
paused := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	pde = load Pde Pde->PATH;
	if(pde == nil){ sys->fprint(sys->fildes(2), "pdelab: cannot load %s: %r\n", Pde->PATH); raise "fail:load"; }
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init(); pde->init();
	if(ctxt == nil) ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "PDE Laboratory", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	pal = array[256] of ref Image;
	for(i := 0; i < 256; i++){
		# Inferno-capable smooth blue/cyan/yellow heat map, not a Temple palette.
		r := clamp(2*i-128); g := clamp(3*i-256); bl := clamp(255-2*i);
		pal[i] = win.display.color((r<<24)|(g<<16)|(bl<<8)|255);
	}
	a = pde->new(NX, NY, 1.0, 1.0, Pde->CLAMP);
	b = pde->new(NX, NY, 1.0, 1.0, Pde->CLAMP);
	if(tl argv != nil){ m := int hd tl argv; if(m >= 1 && m <= 3) mode = m; }
	reset();
	win.reshape(Rect((0,0),(768,576)));
	win.onscreen("place"); win.startinput("kbd"::"ptr"::nil);
	ticks := chan of int; spawn timer(ticks);
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl => win.wmctl(ctl); if(ctl != nil && ctl[0] == '!') redraw();
	p := <-win.ctxt.ptr => win.pointer(*p); pointer(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		'1' or '2' or '3' => mode = k-'0'; reset();
		'r' or 'R' => reset();
		' ' => paused = !paused;
		}
	<-ticks => if(!paused) step(); redraw();
	}
}

reset()
{
	pde->clear(a, 0.0); pde->clear(b, 0.0);
	case mode {
	1 => pde->splat(a, NX/2, NY/2, 8, 1.0);
	2 => pde->splat(a, NX/2, NY/2, 4, 1.0); a.old[:] = a.u;
	3 =>
		pde->clear(a, 1.0);
		pde->splat(a, NX/2, NY/2, 7, 0.45);
		pde->splat(b, NX/2, NY/2, 6, 0.9);
	}
}

step()
{
	case mode {
	1 => pde->diffuse(a, 1.2, 0.8);
	2 => pde->wave(a, 1.0, 0.035, 0.45);
	3 => for(i := 0; i < 4; i++) pde->gray(a, b, 1.0, 0.5, 0.055, 0.062, 0.7);
	}
}

pointer(p: ref Draw->Pointer)
{
	if(win.image == nil || !(p.buttons & 1)) return;
	x := (p.xy.x-win.image.r.min.x)*NX/win.image.r.dx();
	y := (p.xy.y-win.image.r.min.y)*NY/win.image.r.dy();
	if(mode == 3){ pde->splat(a,x,y,4,0.35); pde->splat(b,x,y,3,0.95); }
	else if(mode == 2){ pde->splat(a,x,y,3,1.0); pde->splatold(a,x,y,3,0.7); }
	else pde->splat(a,x,y,4,1.0);
}

redraw()
{
	img := win.image; if(img == nil) return;
	cw := (img.r.dx()+NX-1)/NX; ch := (img.r.dy()+NY-1)/NY;
	for(y := 0; y < NY; y++) for(x := 0; x < NX; x++){
		v := a.u[y*NX+x];
		if(mode == 2) v = (v+1.0)*0.5;
		if(mode == 3) v = b.u[y*NX+x]-a.u[y*NX+x]*0.25+0.25;
		i := clamp(int (v*255.0));
		x0 := img.r.min.x+x*img.r.dx()/NX; y0 := img.r.min.y+y*img.r.dy()/NY;
		img.draw(Rect((x0,y0),(x0+cw,y0+ch)),pal[i],nil,Point(0,0));
	}
	name := array[] of {"", "heat/diffusion", "damped wave", "Gray-Scott reaction-diffusion"};
	img.text(img.r.min.add((8,16)), pal[255], Point(0,0), font,
		sys->sprint("%s  [1-3 select, draw, r reset, space pause]", name[mode]));
	img.flush(Draw->Flushnow);
}

clamp(v: int): int { if(v < 0) return 0; if(v > 255) return 255; return v; }

timer(c: chan of int)
{
	for(;;){ sys->sleep(25); c <-= 1; }
}
