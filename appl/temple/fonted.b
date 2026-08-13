implement Fonted;

# TempleOS Demo/Graphics/FontEd.HC — 8x8 bitmap font editor (simplified)
# GAP: no system text.font / BootHDIns; local glyphs; 's' dumps hex to /tmp

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Fonted: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FW: con 8;
FH: con 8;
CELL: con 10;
BIG: con 24;

win: ref Window;
yellow, blue, white: ref Image;
glyphs: array of array of byte;
cur := 65;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS FontEd", Wmclient->Appl);
	d := win.display;
	yellow = d.color(Draw->Yellow);
	blue = d.color(Draw->Blue);
	white = d.color(Draw->White);
	glyphs = array[256] of array of byte;
	for(i := 0; i < 256; i++)
		glyphs[i] = array[FH] of { * => byte 0 };
	a := array[] of {
		byte 16r18, byte 16r24, byte 16r42, byte 16r42,
		byte 16r7E, byte 16r42, byte 16r42, byte 16r00
	};
	for(i = 0; i < FH; i++)
		glyphs[65][i] = a[i];
	win.reshape(Rect((0, 0), (520, 420)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		's' or 'S' =>
			savehex();
		',' or '<' =>
			cur = (cur + 255) & 255;
			redraw();
		'.' or '>' =>
			cur = (cur + 1) & 255;
			redraw();
		* =>
			if(k >= 32 && k < 127){
				cur = k;
				redraw();
			}
		}
	}
}

ptr(p: ref Draw->Pointer)
{
	if((p.buttons & 1) == 0)
		return;
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	gx := (x - 8) / CELL;
	gy := (y - 40) / CELL;
	if(gx >= 0 && gx < 16 && gy >= 0 && gy < 16){
		cur = gy*16 + gx;
		redraw();
		return;
	}
	bx := (x - 300) / BIG;
	by := (y - 40) / BIG;
	if(bx >= 0 && bx < FW && by >= 0 && by < FH){
		row := glyphs[cur][by];
		bit := byte(16r80 >> bx);
		glyphs[cur][by] = row ^ bit;
		redraw();
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, blue, nil, Point(0, 0));
	o := img.r.min;
	for(i := 0; i < 16; i++)
		for(j := 0; j < 16; j++){
			ch := i*16 + j;
			col := white;
			if(ch == cur)
				col = yellow;
			img.draw(Rect((o.x+8+j*CELL, o.y+40+i*CELL),
				(o.x+8+j*CELL+CELL-1, o.y+40+i*CELL+CELL-1)), col, nil, Point(0, 0));
		}
	for(row := 0; row < FH; row++)
		for(col := 0; col < FW; col++){
			on := (int glyphs[cur][row] & (16r80 >> col)) != 0;
			c := blue;
			if(on)
				c = yellow;
			img.draw(Rect((o.x+300+col*BIG, o.y+40+row*BIG),
				(o.x+300+col*BIG+BIG-1, o.y+40+row*BIG+BIG-1)), c, nil, Point(0, 0));
		}
	win.settitle(sys->sprint("FontEd ch=%d  click bit · ,/. change · s=save · q=quit", cur));
	img.flush(Draw->Flushnow);
}

savehex()
{
	path := "/tmp/temple-font.hex";
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "fonted: %s: %r\n", path);
		return;
	}
	hexd := "0123456789ABCDEF";
	for(ch := 0; ch < 256; ch++){
		sys->fprint(fd, "0x");
		for(r := 0; r < FH; r++){
			v := int glyphs[ch][r];
			sys->fprint(fd, "%c%c", hexd[(v>>4)&15], hexd[v&15]);
		}
		sys->fprint(fd, ",\n");
	}
	win.settitle("FontEd saved "+path);
}
