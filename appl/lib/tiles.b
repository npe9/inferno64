implement Tiles;

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

include "tiles.m";

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
	# FLOOR, not int.  Limbo's int on a real rounds to nearest and rounds
	# a half away from zero, so the twelve hues - which land on exact
	# half sixths - took the wrong sextant every other one, and the
	# fraction within it came out negative.  Two pairs of hues then
	# clamped to the same colour, which is not visible in any single
	# colour and is exactly what tilestest(1) counts.
	h6 := h * 6.0;
	seg := int h6;
	if(real seg > h6)
		seg--;
	if(seg > 5)
		seg = 5;
	if(seg < 0)
		seg = 0;
	f := h6 - real seg;
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
	s.bg = bg;
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

# ---------------------------------------------------- a command language
#
# See tiles(2).  The shape is tk(2)'s: named things, made and drawn by
# text, errors coming back with a "!" on the front.  What it buys is
# that a level, a palette and a sheet of art stop being source and
# become data - a file a program reads, an artist edits, and a shell
# script can write.

Named: adt {
	name:	string;
	pal:	ref Pal;
	chr:	ref Chr;
	surf:	ref Surface;
	# what "map" painted here, so it can be asked about and changed
	grid:	array of string;
	legch:	array of int;
	legpal:	array of ref Pal;
	gsheet:	ref Chr;
};

screen(d: ref Display, chans: Chans, scale: int): ref Screen
{
	if(d == nil || scale < 1)
		return nil;
	s := ref Screen;
	s.disp = d;
	s.chans = chans;
	s.scale = scale;
	names = array[0] of ref Named;
	return s;
}

names: array of ref Named;

find(n: string): ref Named
{
	for(i := 0; i < len names; i++)
		if(names[i].name == n)
			return names[i];
	return nil;
}

bind(n: string): ref Named
{
	e := find(n);
	if(e != nil)
		return e;
	e = ref Named(n, nil, nil, nil, nil, nil, nil, nil);
	a := array[len names + 1] of ref Named;
	a[0:] = names;
	a[len names] = e;
	names = a;
	return e;
}

Screen.image(s: self ref Screen, name: string): ref Image
{
	e := find(name);
	if(e == nil || e.surf == nil)
		return nil;
	return e.surf.img;
}

Screen.named(s: self ref Screen, name: string): ref Surface
{
	e := find(name);
	if(e == nil)
		return nil;
	return e.surf;
}

Screen.sheet(s: self ref Screen, name: string): ref Chr
{
	e := find(name);
	if(e == nil)
		return nil;
	return e.chr;
}

Screen.pal(s: self ref Screen, name: string): ref Pal
{
	e := find(name);
	if(e == nil)
		return nil;
	return e.pal;
}

# A colour, as ROW.COLUMN or as a bare master index.  Named is what an
# artist writes; the index is what a program that has already worked one
# out passes back in.
rowname := array[] of {"dark", "mid", "light", "pale"};
colname := array[] of {"grey", "red", "orange", "yellow", "lime", "green",
	"spring", "cyan", "azure", "blue", "violet", "magenta", "rose",
	"black", "black", "black"};

parsecolour(w: string): (int, string)
{
	dot := -1;
	for(i := 0; i < len w; i++)
		if(w[i] == '.')
			dot = i;
	if(dot < 0){
		if(len w == 0 || w[0] < '0' || w[0] > '9')
			return (0, "not a colour: " + w);
		v := int w;
		if(v < 0 || v >= MASTER)
			return (0, "colour out of range: " + w);
		return (v, nil);
	}
	r := -1;
	for(i = 0; i < len rowname; i++)
		if(rowname[i] == w[0:dot])
			r = i;
	c := -1;
	for(i = 0; i < len colname; i++)
		if(colname[i] == w[dot+1:])
			c = i;
	if(r < 0)
		return (0, "no such row: " + w[0:dot]);
	if(c < 0)
		return (0, "no such colour: " + w[dot+1:]);
	return (entry(r, c), nil);
}

# Lines of a file.  Comments begin with ";" and NOT with "#", which was
# the first choice and is a trap: "#" is the obvious character for a
# wall in a map, so the legend line
#
#	# 1 brick
#
# was thrown away as a comment and every brick in the demo map silently
# failed to draw.  A format whose comment marker collides with its own
# data is a bad format; ";" collides with nothing anyone draws with.
#
# strip says whether blank lines go too.  For art they are meaningless -
# a tile is exactly eight lines - and they let a sheet be laid out to be
# read.  For the grid of a map a blank line is a blank ROW, and dropping
# it moves everything below it up.
readlines(path: string, strip: int): (array of string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sys->sprint("cannot stat %s: %r", path));
	n := int d.length;
	if(n <= 0 || n > 1024*1024)
		return (nil, "unreasonable file: " + path);
	b := array[n] of byte;
	if(sys->readn(fd, b, n) != n)
		return (nil, sys->sprint("cannot read %s: %r", path));
	(nl, l) := sys->tokenize(string b, "\n");
	out := array[nl] of string;
	k := 0;
	for(; l != nil; l = tl l){
		w := hd l;
		if(len w > 0 && w[0] == ';')
			continue;
		if(strip && len w == 0)
			continue;
		out[k++] = w;
	}
	return (out[0:k], nil);
}

Screen.cmd(s: self ref Screen, command: string): string
{
	# Several commands, newline separated, like tk(2) and plot(2).  The
	# first that fails stops the rest, and its error is the answer.
	nlat := -1;
	for(i := 0; i < len command; i++)
		if(command[i] == '\n')
			nlat = i;
	if(nlat >= 0){
		(nil, lines) := sys->tokenize(command, "\n");
		r := "";
		for(; lines != nil; lines = tl lines){
			w := hd lines;
			if(len w == 0 || w[0] == '#')
				continue;
			r = s.cmd(w);
			if(len r > 0 && r[0] == '!')
				return r;
		}
		return r;
	}
	(na, a) := sys->tokenize(command, " \t\r");
	if(na == 0)
		return "";
	v := array[na] of string;
	for(i = 0; i < na; i++){
		v[i] = hd a;
		a = tl a;
	}
	return docmd(s, v);
}

usage(u: string): string
{
	return "!usage: " + u;
}

docmd(s: ref Screen, a: array of string): string
{
	case a[0] {
	"palette" =>
		if(len a != 6)
			return usage("palette NAME c0 c1 c2 c3");
		c := array[4] of int;
		for(i := 0; i < 4; i++){
			(v, e) := parsecolour(a[2+i]);
			if(e != nil)
				return "!" + e;
			c[i] = v;
		}
		bind(a[1]).pal = pal(c[0], c[1], c[2], c[3]);
		return "";
	"sheet" or "sheet16" =>
		if(len a != 3)
			return usage(a[0] + " NAME FILE");
		(lines, e) := readlines(a[2], 1);
		if(e != nil)
			return "!" + e;
		art := lines;
		if(a[0] == "sheet16"){
			if(len lines % 16 != 0)
				return "!" + a[2] + ": not a multiple of 16 lines";
			art = meta(lines);
		}else if(len lines % 8 != 0)
			return "!" + a[2] + ": not a multiple of 8 lines";
		bind(a[1]).chr = chr(s.disp, s.chans, s.scale, art);
		return "";
	"font" =>
		if(len a != 2)
			return usage("font NAME");
		f := font(s.disp, s.chans, s.scale);
		if(f == nil)
			return "!cannot open the 8x8 font";
		bind(a[1]).chr = f;
		# Remember which name it went under.  fontof() used to look for
		# the literal name "font", so a font declared under any other
		# name was never found and every surface silently took the
		# first tile sheet as its font instead: text() then drew road
		# tiles for letters, or nothing, with no error anywhere.
		fontname = a[1];
		return "";
	"surface" =>
		if(len a != 5)
			return usage("surface NAME W H COLOUR");
		(bg, e) := parsecolour(a[4]);
		if(e != nil)
			return "!" + e;
		w := int a[2];
		h := int a[3];
		if(w < 1 || h < 1)
			return "!surface: silly size";
		# A surface needs a sheet to take its scale and channels from,
		# and it does not care which: any sheet this screen made has
		# the screen's own.  One is made here if there is none yet.
		if(anychr(s) == nil)
			return "!surface: declare a sheet or a font first";
		su := surface(s.disp, anychr(s), fontof(s), w, h, bg);
		if(su == nil)
			return "!surface: cannot allocate";
		bind(a[1]).surf = su;
		return "";
	"tile" or "put" or "put16" =>
		if(len a < 7)
			return usage(a[0] + " SURF X Y SHEET N PAL [flipx] [flipy]");
		(su, sh, pl, e) := three(a[1], a[4], a[6]);
		if(e != nil)
			return "!" + e;
		n := int a[5];
		if(n < 0 || n >= sh.n)
			return "!" + a[4] + ": no tile " + a[5];
		fl := 0;
		for(i := 7; i < len a; i++){
			case a[i] {
			"flipx" =>	fl |= FLIPX;
			"flipy" =>	fl |= FLIPY;
			*  =>		return "!unknown flag " + a[i];
			}
		}
		x := int a[2];
		y := int a[3];
		old := su.chr;
		su.chr = sh;
		case a[0] {
		"tile" =>	su.tile(x, y, n, pl);
		"put" =>	su.put(x, y, n, pl, fl);
		*  =>		su.put16(x, y, n, pl, fl);
		}
		su.chr = old;
		return "";
	"text" =>
		if(len a < 6)
			return usage("text SURF X Y PAL WORDS...");
		su := surfof(a[1]);
		if(su == nil)
			return "!no surface " + a[1];
		pl := palof(a[4]);
		if(pl == nil)
			return "!no palette " + a[4];
		t := a[5];
		for(i := 6; i < len a; i++)
			t += " " + a[i];
		su.text(int a[2], int a[3], t, pl);
		return "";
	"fill" =>
		if(len a != 7)
			return usage("fill SURF X Y W H COLOUR");
		su := surfof(a[1]);
		if(su == nil)
			return "!no surface " + a[1];
		(c, e) := parsecolour(a[6]);
		if(e != nil)
			return "!" + e;
		x := int a[2];
		y := int a[3];
		su.fill(Rect((x, y), (x + int a[4], y + int a[5])), c);
		return "";
	"view" or "blit" =>
		if(len a != 5)
			return usage(a[0] + " SRC DST X Y");
		src := surfof(a[1]);
		dst := surfof(a[2]);
		if(src == nil)
			return "!no surface " + a[1];
		if(dst == nil)
			return "!no surface " + a[2];
		if(a[0] == "view")
			src.view(dst, int a[3], int a[4]);
		else
			src.blit(dst, int a[3], int a[4]);
		return "";
	"map" =>
		if(len a != 4)
			return usage("map SURF SHEET FILE");
		return domap(a[1], a[2], a[3]);
	"at" =>
		if(len a != 4)
			return usage("at SURF X Y");
		e := find(a[1]);
		if(e == nil || e.grid == nil)
			return "!no map on " + a[1];
		(x, y) := (int a[2], int a[3]);
		if(y < 0 || y >= len e.grid)
			return "";
		row := e.grid[y];
		if(x < 0 || x >= len row)
			return "";
		return row[x:x+1];
	"set" =>
		if(len a != 5)
			return usage("set SURF X Y CHAR|blank");
		e := find(a[1]);
		if(e == nil || e.grid == nil)
			return "!no map on " + a[1];
		# "blank" and not " ".  A command is a line of words split on
		# spaces, so a space cannot be an argument: `set lvl 3 4 " "`
		# arrives as four words and does nothing at all, silently,
		# which is how leap(1)'s coins stopped being collectable.  A
		# language whose alphabet cannot express one of its own values
		# needs a word for it.
		c := ' ';
		if(a[4] != "blank"){
			if(len a[4] != 1)
				return "!set: want one character or blank";
			c = a[4][0];
		}
		return setcell(e, int a[2], int a[3], c);
	"size" =>
		if(len a != 2)
			return usage("size SURF");
		su := surfof(a[1]);
		if(su == nil)
			return "!no surface " + a[1];
		return sys->sprint("%d %d", su.w, su.h);
	"colour" =>
		if(len a != 2)
			return usage("colour NAME");
		(c, e) := parsecolour(a[1]);
		if(e != nil)
			return "!" + e;
		v := rgb(c);
		return sys->sprint("#%02x%02x%02x", (v>>24) & 16rFF,
			(v>>16) & 16rFF, (v>>8) & 16rFF);
	"count" =>
		if(len a != 2)
			return usage("count SHEET");
		ch := chrof(a[1]);
		if(ch == nil)
			return "!no sheet " + a[1];
		return string ch.n;
	}
	return "!no such command: " + a[0];
}

three(sn, cn, pn: string): (ref Surface, ref Chr, ref Pal, string)
{
	su := surfof(sn);
	if(su == nil)
		return (nil, nil, nil, "no surface " + sn);
	ch := chrof(cn);
	if(ch == nil)
		return (nil, nil, nil, "no sheet " + cn);
	pl := palof(pn);
	if(pl == nil)
		return (nil, nil, nil, "no palette " + pn);
	return (su, ch, pl, nil);
}

surfof(n: string): ref Surface
{
	e := find(n);
	if(e == nil)
		return nil;
	return e.surf;
}

chrof(n: string): ref Chr
{
	e := find(n);
	if(e == nil)
		return nil;
	return e.chr;
}

palof(n: string): ref Pal
{
	e := find(n);
	if(e == nil)
		return nil;
	return e.pal;
}

anychr(s: ref Screen): ref Chr
{
	for(i := 0; i < len names; i++)
		if(names[i].chr != nil)
			return names[i].chr;
	return nil;
}

# The name the font command last bound, so a font may be called
# whatever its author likes.
fontname := "font";

fontof(s: ref Screen): ref Chr
{
	e := find(fontname);
	if(e == nil || e.chr == nil)
		e = find("font");
	if(e != nil && e.chr != nil)
		return e.chr;
	return anychr(s);
}

# A map file carries its own legend, so a level is one file and not a
# file plus an argument list nobody can read:
#
#	G 1 steel
#	H 2 wood
#	%
#	....GGGG....
#
# A character with no legend entry paints nothing, which is how a map
# says "sky" without naming it.
domap(sn, cn, path: string): string
{
	su := surfof(sn);
	if(su == nil)
		return "!no surface " + sn;
	ch := chrof(cn);
	if(ch == nil)
		return "!no sheet " + cn;
	# The legend is read with blank lines dropped, the grid without: a
	# blank line in a map is a blank row.
	(lines, e) := readlines(path, 0);
	if(e != nil)
		return "!" + e;
	legch := array[256] of int;
	legpal := array[256] of ref Pal;
	for(i := 0; i < 256; i++)
		legch[i] = -1;
	i = 0;
	for(; i < len lines; i++){
		if(lines[i] == "%"){
			i++;
			break;
		}
		if(lines[i] == "")
			continue;
		(nw, w) := sys->tokenize(lines[i], " \t");
		if(nw != 3)
			return "!" + path + ": legend wants CHAR TILE PALETTE";
		c := (hd w)[0];
		w = tl w;
		t := int hd w;
		w = tl w;
		pl := palof(hd w);
		if(pl == nil)
			return "!no palette " + hd w;
		if(t < 0 || t >= ch.n)
			return "!" + cn + ": no tile " + string t;
		legch[c] = t;
		legpal[c] = pl;
	}
	old := su.chr;
	su.chr = ch;
	grid := array[len lines - i] of string;
	ty := 0;
	for(; i < len lines; i++){
		row := lines[i];
		grid[ty] = row;
		for(tx := 0; tx < len row; tx++){
			c := row[tx];
			if(c > 255 || legch[c] < 0)
				continue;
			su.tile(tx, ty, legch[c], legpal[c]);
		}
		ty++;
	}
	su.chr = old;
	en := bind(sn);
	en.grid = grid[0:ty];
	en.legch = legch;
	en.legpal = legpal;
	en.gsheet = ch;
	return "";
}

# One cell, changed and repainted.  A character the legend does not
# mention clears the cell to the surface's background, which is how a
# script says "the coin is gone".
setcell(e: ref Named, x, y: int, c: int): string
{
	if(y < 0 || y >= len e.grid)
		return "!set: no such row";
	row := e.grid[y];
	if(x < 0 || x >= len row)
		return "!set: no such column";
	# NOT `string c`: c is a character code and string of an int is its
	# digits, so setting a cell to '.' spliced "46" into the row and
	# the next "at" answered "4".  A one-character string is made by
	# assigning to the end of one.
	one := "";
	one[0] = c;
	e.grid[y] = row[0:x] + one + row[x+1:];
	su := e.surf;
	old := su.chr;
	su.chr = e.gsheet;
	if(c <= 255 && e.legch[c] >= 0)
		su.tile(x, y, e.legch[c], e.legpal[c]);
	else
		su.fill(Rect((x*TW, y*TH), (x*TW+TW, y*TH+TH)), bgof(su));
	su.chr = old;
	return "";
}

# The colour a surface was made with, remembered so "set" can clear a
# cell back to it.
bgof(su: ref Surface): int
{
	return su.bg;
}
