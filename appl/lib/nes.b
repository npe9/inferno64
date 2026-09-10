implement Nes;

# See module/nes.m for what this is and is not.
#
# The two things that shape the whole file:
#
#   draw() does not resample.  So a tile is composited ONCE at the
#   destination's scale, into an 8*scale square image, and every draw
#   after that is 1:1.  Nothing is scaled per frame.
#
#   A composite is per (tile, palette, flip) and is built on first use.
#   A sheet of 96 tiles at four palettes and four flips is 1536 of them,
#   and a game touches a few dozen; building them all up front would
#   cost more than the game does.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Chans: import draw;

include "tone.m";
	tone: Tone;

include "keyboard.m";

include "nes.m";

# The master palette's shape.  Four rows of sixteen: a grey, twelve
# hues, three blacks.  Changing these moves the whole ramp together,
# which is the point of computing it rather than writing it out.
NROW:	con 4;
NCOL:	con 16;
NHUE:	con 12;

# Row r's luma and saturation.  Row 0 is the dark shade a sprite is
# outlined in, row 3 the near-white a highlight uses.
lum := array[NROW] of {0.35, 0.62, 0.85, 1.00};
sat := array[NROW] of {1.00, 1.00, 0.60, 0.25};
# Where hue 0 sits, in turns.  0.0 is red.
HUE0:	con 0.0;

master: array of int;		# NROW*NCOL RGBA values
colcache: array of ref Image;
colcachedisp: ref Display;

inited := 0;

init(): string
{
	if(inited)
		return nil;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		return sys->sprint("cannot load draw: %r");
	master = array[NROW*NCOL] of int;
	for(r := 0; r < NROW; r++){
		for(c := 0; c < NCOL; c++){
			v := 0;
			if(c == 0)
				v = grey(lum[r]);
			else if(c <= NHUE)
				v = hue(HUE0 + real (c-1) / real NHUE, sat[r], lum[r]);
			else
				v = 16r000000FF;
			master[r*NCOL + c] = v;
		}
	}
	inited = 1;
	return nil;
}

# Limbo's int on a real rounds to nearest already, so nothing here adds
# a half first: doing both rounds twice and lands a step high.
grey(l: real): int
{
	v := clamp(int (l * 255.0));
	return (v << 24) | (v << 16) | (v << 8) | 16rFF;
}

# Plain HSV: the row gives the value and the saturation, the column the
# hue.  An earlier version normalised each hue to the row's luma so a
# yellow and a blue would read as equally bright.  That is the right
# thing for a chart and the wrong thing here - it drives the saturated
# hues past full scale at the bright rows, where they clip and come back
# as the same colour.  A console palette wants the primaries bright.
hue(h, s, l: real): int
{
	while(h >= 1.0)
		h -= 1.0;
	while(h < 0.0)
		h += 1.0;
	seg := int (h * 6.0);
	if(seg > 5)
		seg = 5;
	f := h * 6.0 - real seg;
	p := 1.0 - s;
	q := 1.0 - s*f;
	t := 1.0 - s*(1.0 - f);
	r, g, b: real;
	case seg {
	0 =>	(r, g, b) = (1.0, t, p);
	1 =>	(r, g, b) = (q, 1.0, p);
	2 =>	(r, g, b) = (p, 1.0, t);
	3 =>	(r, g, b) = (p, q, 1.0);
	4 =>	(r, g, b) = (t, p, 1.0);
	*  =>	(r, g, b) = (1.0, p, q);
	}
	ri := clamp(int (r*l*255.0));
	gi := clamp(int (g*l*255.0));
	bi := clamp(int (b*l*255.0));
	return (ri << 24) | (gi << 16) | (bi << 8) | 16rFF;
}

clamp(v: int): int
{
	if(v < 0)
		return 0;
	if(v > 255)
		return 255;
	return v;
}

entry(row, col: int): int
{
	if(row < 0) row = 0;
	if(row >= NROW) row = NROW-1;
	if(col < 0) col = 0;
	if(col >= NCOL) col = NCOL-1;
	return row*NCOL + col;
}

rgb(i: int): int
{
	if(master == nil || i < 0 || i >= len master)
		return 16r000000FF;
	return master[i];
}

colour(d: ref Display, i: int): ref Image
{
	if(d == nil)
		return nil;
	if(colcache == nil || colcachedisp != d){
		colcache = array[MASTER] of ref Image;
		colcachedisp = d;
	}
	if(i < 0 || i >= MASTER)
		i = 0;
	if(colcache[i] == nil){
		v := rgb(i);
		colcache[i] = d.rgb((v>>24) & 16rFF, (v>>16) & 16rFF, (v>>8) & 16rFF);
	}
	return colcache[i];
}

pal(a, b, c, e: int): ref Pal
{
	p := ref Pal;
	p.c = array[4] of {a, b, c, e};
	return p;
}

# ---------------------------------------------------------------- tiles

NFLIP:	con 4;

chr(d: ref Display, chans: Chans, scale: int, art: array of string): ref Chr
{
	if(scale < 1)
		scale = 1;
	n := len art / TH;
	c := ref Chr;
	c.n = n;
	c.scale = scale;
	c.disp = d;
	c.chans = chans;
	c.npal = 0;
	c.pals = array[8] of ref Pal;
	c.img = array[8 * n * NFLIP] of ref Image;
	c.msk = array[8 * n * NFLIP] of ref Image;
	c.bits = array[n * TW * TH] of byte;
	for(t := 0; t < n; t++){
		for(y := 0; y < TH; y++){
			row := art[t*TH + y];
			for(x := 0; x < TW; x++){
				v := 0;
				if(x < len row){
					case row[x] {
					'1' =>	v = 1;
					'2' =>	v = 2;
					'3' =>	v = 3;
					}
				}
				c.bits[t*TW*TH + y*TW + x] = byte v;
			}
		}
	}
	return c;
}

Chr.pix(c: self ref Chr, t, x, y: int): int
{
	if(t < 0 || t >= c.n || x < 0 || x >= TW || y < 0 || y >= TH)
		return 0;
	return int c.bits[t*TW*TH + y*TW + x];
}

meta(art: array of string): array of string
{
	nb := len art / 16;
	out := array[nb * 4 * TH] of string;
	for(b := 0; b < nb; b++){
		for(q := 0; q < 4; q++){
			ox := (q & 1) * TW;
			oy := (q >> 1) * TH;
			for(y := 0; y < TH; y++){
				row := art[b*16 + oy + y];
				o := "";
				for(x := 0; x < TW; x++){
					c := '.';
					if(ox + x < len row)
						c = row[ox + x];
					o[len o] = c;
				}
				out[(b*4 + q)*TH + y] = o;
			}
		}
	}
	return out;
}

# The 8x8 text font.  /fonts/temple/temple.8x8 is a k1 subfont, 256
# glyphs of eight pixels laid out in one 2048x8 row, and it is already
# in the tree - so this reads it rather than carrying another table.
# Glyph i becomes tile i, so a string indexes the sheet directly.
font(d: ref Display, chans: Chans, scale: int): ref Chr
{
	if(d == nil)
		return nil;
	f := d.open("/fonts/temple/temple.8x8");
	if(f == nil)
		return nil;
	w := f.r.dx();
	h := f.r.dy();
	if(h < TH || f.depth != 1)
		return nil;
	# The rectangle starts at x=0, so the row length is the simple one;
	# masktest(1) is where the general case is spelled out.
	bpl := (w + 7) / 8;
	b := array[bpl * h] of byte;
	if(f.readpixels(f.r, b) < 0)
		return nil;
	n := w / TW;
	if(n > 256)
		n = 256;
	art := array[n * TH] of string;
	for(t := 0; t < n; t++){
		for(y := 0; y < TH; y++){
			s := "";
			for(x := 0; x < TW; x++){
				px := t*TW + x;
				if((int b[y*bpl + (px>>3)] & (16r80 >> (px & 7))) != 0)
					s[len s] = '1';
				else
					s[len s] = '.';
			}
			art[t*TH + y] = s;
		}
	}
	return chr(d, chans, scale, art);
}

# The palette's slot in this sheet's composite cache, registering it if
# it is new.  A game uses a handful, so the scan is short and the last
# hit is remembered because the inner loop asks for the same one over
# and over.
lastchr: ref Chr;
lastpal: ref Pal;
lastidx := 0;

palindex(c: ref Chr, p: ref Pal): int
{
	if(c == lastchr && p == lastpal)
		return lastidx;
	for(i := 0; i < c.npal; i++){
		if(c.pals[i] == p){
			lastchr = c;
			lastpal = p;
			lastidx = i;
			return i;
		}
	}
	if(c.npal >= len c.pals){
		np := array[len c.pals * 2] of ref Pal;
		np[0:] = c.pals;
		c.pals = np;
		ni := array[len np * c.n * NFLIP] of ref Image;
		ni[0:] = c.img;
		c.img = ni;
		nm := array[len np * c.n * NFLIP] of ref Image;
		nm[0:] = c.msk;
		c.msk = nm;
	}
	i = c.npal++;
	c.pals[i] = p;
	lastchr = c;
	lastpal = p;
	lastidx = i;
	return i;
}

# Build the composite for one (tile, palette, flip).  Four 1-bit
# coverage bitmaps are written whole and the four colours drawn through
# them; that is four writepixels and four draws a composite, against
# sixty-four draws if each logical pixel were a rectangle of its own.
build(c: ref Chr, pi, t, flip: int)
{
	k := (pi * c.n + t) * NFLIP + flip;
	if(c.img[k] != nil)
		return;
	s := c.scale;
	w := TW * s;
	h := TH * s;
	im := c.disp.newimage(Rect((0,0),(w,h)), c.chans, 0, Draw->Black);
	cov := c.disp.newimage(Rect((0,0),(w,h)), Draw->GREY1, 0, Draw->Black);
	if(im == nil || cov == nil)
		return;
	bpl := (w + 7) / 8;
	covb := array[bpl * h] of { * => byte 0 };
	p := c.pals[pi];
	for(ci := 0; ci < 4; ci++){
		bits := array[bpl * h] of { * => byte 0 };
		any := 0;
		for(y := 0; y < TH; y++){
			sy := y;
			if(flip & FLIPY)
				sy = TH-1 - y;
			for(x := 0; x < TW; x++){
				sx := x;
				if(flip & FLIPX)
					sx = TW-1 - x;
				if(int c.bits[t*TW*TH + sy*TW + sx] != ci)
					continue;
				any = 1;
				for(dy := 0; dy < s; dy++){
					pr := (y*s + dy) * bpl;
					for(dx := 0; dx < s; dx++){
						px := x*s + dx;
						bits[pr + (px>>3)] |= byte (16r80 >> (px & 7));
						if(ci != 0)
							covb[pr + (px>>3)] |= byte (16r80 >> (px & 7));
					}
				}
			}
		}
		if(!any)
			continue;
		m := c.disp.newimage(Rect((0,0),(w,h)), Draw->GREY1, 0, Draw->Black);
		if(m == nil)
			continue;
		m.writepixels(m.r, bits);
		im.draw(im.r, colour(c.disp, p.c[ci]), m, (0,0));
	}
	cov.writepixels(cov.r, covb);
	c.img[k] = im;
	c.msk[k] = cov;
}

# ------------------------------------------------------------- surfaces

surface(d: ref Display, ch, fnt: ref Chr, w, h, bg: int): ref Surface
{
	if(d == nil || ch == nil)
		return nil;
	s := ref Surface;
	s.chr = ch;
	s.fnt = fnt;
	s.scale = ch.scale;
	s.w = w;
	s.h = h;
	s.img = d.newimage(Rect((0,0),(w*s.scale, h*s.scale)), ch.chans, 0, rgb(bg));
	if(s.img == nil)
		return nil;
	return s;
}

Surface.tile(s: self ref Surface, tx, ty, t: int, p: ref Pal)
{
	drawtile(s, s.chr, tx*TW, ty*TH, t, p, 0, 0);
}

Surface.put(s: self ref Surface, x, y, t: int, p: ref Pal, flags: int)
{
	drawtile(s, s.chr, x, y, t, p, flags, 1);
}

Surface.put16(s: self ref Surface, x, y, t: int, p: ref Pal, flags: int)
{
	f := flags & (FLIPX|FLIPY);
	for(q := 0; q < 4; q++){
		sq := q;
		if(f & FLIPX)
			sq ^= 1;
		if(f & FLIPY)
			sq ^= 2;
		drawtile(s, s.chr, x + (q & 1)*TW, y + (q >> 1)*TH, t + sq, p, f, 1);
	}
}

Surface.text(s: self ref Surface, x, y: int, str: string, p: ref Pal)
{
	if(s.fnt == nil)
		return;
	for(i := 0; i < len str; i++){
		ch := str[i];
		if(ch >= s.fnt.n)
			ch = '?';
		if(ch != ' ')
			drawtile(s, s.fnt, x + i*TW, y, ch, p, 0, 1);
	}
}

drawtile(s: ref Surface, c: ref Chr, x, y, t: int, p: ref Pal, flags, masked: int)
{
	if(c == nil || t < 0 || t >= c.n)
		return;
	pi := palindex(c, p);
	flip := flags & (FLIPX|FLIPY);
	build(c, pi, t, flip);
	k := (pi * c.n + t) * NFLIP + flip;
	im := c.img[k];
	if(im == nil)
		return;
	sc := s.scale;
	r := Rect((x*sc, y*sc), (x*sc + TW*sc, y*sc + TH*sc));
	m: ref Image = nil;
	if(masked)
		m = c.msk[k];
	s.img.draw(r, im, m, (0,0));
}

Surface.fill(s: self ref Surface, r: Rect, ci: int)
{
	sc := s.scale;
	d := Rect((r.min.x*sc, r.min.y*sc), (r.max.x*sc, r.max.y*sc));
	s.img.draw(d, colour(s.img.display, ci), nil, (0,0));
}

# The scroll.  sx and sy are clamped so the window stays inside s: draw()
# replicates a source smaller than the destination rather than stopping
# at its edge, so running off the end would tile the level rather than
# show nothing, which is a bug that looks like a feature.
Surface.view(s: self ref Surface, dst: ref Surface, sx, sy: int)
{
	if(dst == nil)
		return;
	mx := s.w - dst.w;
	my := s.h - dst.h;
	if(mx < 0) mx = 0;
	if(my < 0) my = 0;
	if(sx < 0) sx = 0;
	if(sy < 0) sy = 0;
	if(sx > mx) sx = mx;
	if(sy > my) sy = my;
	sc := s.scale;
	dst.img.draw(dst.img.r, s.img, nil,
		Point(s.img.r.min.x + sx*sc, s.img.r.min.y + sy*sc));
}

Surface.blit(s: self ref Surface, dst: ref Surface, x, y: int)
{
	if(dst == nil)
		return;
	sc := dst.scale;
	r := Rect((x*sc, y*sc), (x*sc + s.img.r.dx(), y*sc + s.img.r.dy()));
	dst.img.draw(r, s.img, nil, s.img.r.min);
}

# ---------------------------------------------------------------- input

# The pad, and the keys that work it.  Two sets for the directions so
# either hand can drive, and three for the two buttons because no
# arrangement suits everyone.
padkeys := array[] of {
	(Keyboard->Left, PLEFT), ('a', PLEFT), ('A', PLEFT),
	(Keyboard->Right, PRIGHT), ('d', PRIGHT), ('D', PRIGHT),
	(Keyboard->Up, PUP), ('w', PUP), ('W', PUP),
	(Keyboard->Down, PDOWN), ('s', PDOWN), ('S', PDOWN),
	('z', PB), ('Z', PB), (',', PB),
	('x', PA), ('X', PA), ('.', PA), (' ', PA),
	('\n', PSTART), ('\t', PSEL),
};

padkey(pad, k: int): int
{
	up := 0;
	if((k & (Keyboard->Spec | 16r800)) == Keyboard->Keyup){
		up = 1;
		k &= 16r7ff;
	}
	for(i := 0; i < len padkeys; i++){
		(key, bit) := padkeys[i];
		match := key;
		if(up)
			match = key & 16r7ff;
		if(k != match)
			continue;
		if(up)
			return pad & ~bit;
		return pad | bit;
	}
	return pad;
}

edge(pad, prev: int): int
{
	return pad & ~prev;
}

# ---------------------------------------------------------------- sound

# tone(2) plays one thing at a time and beep() returns at once, so what
# is needed is an arbiter: an effect states a priority and how long it
# lasts, and a quieter one asked for while a louder one is still
# sounding is dropped rather than cutting it off.
haveaudio := 0;
sfxpri := 0;
sfxuntil := 0;

sound(on: int): int
{
	if(!on){
		if(haveaudio && tone != nil)
			tone->stop();
		haveaudio = 0;
		return 0;
	}
	if(haveaudio)
		return 1;
	if(tone == nil)
		tone = load Tone Tone->PATH;
	if(tone == nil)
		return 0;
	if(tone->init() != nil)
		return 0;
	haveaudio = 1;
	return 1;
}

sfx(pri, freq, ms: int)
{
	if(!haveaudio || ms <= 0)
		return;
	now := sys->millisec();
	if(now < sfxuntil && pri < sfxpri)
		return;
	tone->beep(freq, ms);
	sfxpri = pri;
	sfxuntil = now + ms;
}

sfxtick()
{
	if(haveaudio && sys->millisec() >= sfxuntil)
		sfxpri = 0;
}

quiet()
{
	if(haveaudio && tone != nil)
		tone->stop();
	sfxpri = 0;
	sfxuntil = 0;
}
