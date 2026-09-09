implement Vsprite;

# TempleOS's Sprite3 as a first-class type: a display list of drawing
# elements, rasterised here instead of walked element by element by each
# of the seven ports that read one.
#
# The interpreter is not new.  temple/spriteedit(1) has had one since the
# sprites were extracted, because an editor has to draw what it is
# editing; this is that interpreter hoisted out of it, so there is one
# implementation of what an element means rather than one per caller.
# The element vocabulary and its numbering are TempleOS's SPT_*, and the
# text form is what scripts/tos_extract_sprites.py writes.
#
# What a caller gets that walking the list itself does not: the sprite
# comes out at whatever size is asked for, from the vector form, rather
# than at the one size somebody rasterised it to.
#
# The bounding box is computed the way the extractor computes it - from
# the pixels that actually came out, not from the elements' nominal
# extents - so a sprite rendered here and the .bit beside it are the same
# rectangle by construction rather than by argument.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

include "math.m";
	math: Math;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "grpalette.m";
	grpal: Grpalette;

include "math/vsprite.m";

names := array[] of {
	"end", "color", "dither", "thick", "planarsym",
	"transform_on", "transform_off", "shift", "pt", "polypt",
	"line", "polyline", "rect", "rotrect", "circle",
	"ellipse", "polygon", "bspline2", "bspline2closed",
	"bspline3", "bspline3closed", "floodfill", "floodfillnot",
	"bitmap", "mesh", "shiftmesh", "arrow", "text",
	"textbox", "textdiamond",
};

WHITE: con 15;

# The canvas holds one palette index a pixel, not a colour: everything
# that draws goes through setpix with an index, so the RGBA the canvas
# used to hold was built only to be searched back into an index a pixel
# at a time.  UNDRAWN is a value no element can paint.
UNDRAWN: con 254;

# The raster and the pen state it carries, which is exactly TempleOS's
# DC: a colour, an optional dither pair, a thickness, an accumulated
# shift, and a symmetry plane.
rw, rh: int;
rbuf: array of byte;			# rw*rh, one palette index a pixel
fseen, fzero: array of byte;		# flood-fill scratch
fstack: array of int;
rcol := 0; rd0 := -1; rd1 := 0; rthk := 1;
rsx := 0; rsy := 0;
symon := 0;
sax, say, sbx, sby: real;
pal: array of int;
palimg: array of ref Image;
display: ref Display;
font: ref Font;

init()
{
	if(sys != nil)
		return;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	bufio = load Bufio Bufio->PATH;
	grpal = load Grpalette Grpalette->PATH;
	if(grpal != nil){
		grpal->init();
		pal = grpal->values();
	}
}

# The display is needed only for the text elements, which are rasterised
# through a real font; everything else is arithmetic on rbuf.
setdisplay(d: ref Display)
{
	if(d == nil || display == d)
		return;
	display = d;
	palimg = array[Grpalette->COLORS] of ref Image;
	for(i := 0; i < Grpalette->COLORS; i++)
		palimg[i] = d.color(pal[i]);
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
}

kindname(k: int): string
{
	if(k < 0 || k >= NKIND)
		return "?";
	return names[k];
}

mkelem(kind, na: int): ref Elem
{
	e := ref Elem;
	e.kind = kind;
	e.a = array[na] of { * => 0 };
	e.ang = 0.0;
	e.pts = nil;
	e.data = nil;
	e.txt = "";
	e.tw = e.th = 0;
	e.tras = nil;
	e.tag = 0;
	return e;
}

copyelem(e: ref Elem): ref Elem
{
	c := ref *e;
	if(e.a != nil){ c.a = array[len e.a] of int; c.a[0:] = e.a; }
	if(e.pts != nil){ c.pts = array[len e.pts] of int; c.pts[0:] = e.pts; }
	if(e.data != nil){ c.data = array[len e.data] of byte; c.data[0:] = e.data; }
	c.tw = c.th = 0;
	c.tras = nil;
	return c;
}

setpix(x, y, c: int)
{
	if(x < 0 || x >= rw || y < 0 || y >= rh)
		return;
	if(c != TRANSP)
		c &= 15;
	rbuf[y*rw+x] = byte c;
}

getpix(x, y: int): int
{
	if(x < 0 || x >= rw || y < 0 || y >= rh)
		return -1;
	return int rbuf[y*rw+x];
}

# The colour an index stands for, as the canvas used to hold it.  A flood
# fill compares what is under it with what it is about to paint, and it
# has to keep comparing colours rather than indices: TRANSP paints opaque
# white and so does WHITE, so the two are the same pixel to a fill, and
# were before this held indices.
colval(v: int): int
{
	if(v == UNDRAWN || v < 0)
		return 0;
	# Masked, not just shifted: the palette entries are sign-extended
	# 32-bit values and int is 64 bits here, so pal[WHITE] is -1 while
	# the canvas used to hold 16rFFFFFFFF positive.  Comparing the two
	# forms would tell TRANSP from WHITE, which the RGBA canvas could
	# not, and a fill would stop where it used to run on.
	if(v == TRANSP)
		return int 16rFFFFFFFF;
	return (pal[v&15] & int 16rFFFFFF00) | 16rFF;
}

# Where the sprite's origin sits in the canvas.  The canvas IS the
# sprite's box - the same rectangle scripts/tos_extract_sprites.py
# rasterises into - so the dither parity and the flood fill's edges fall
# where the extractor puts them, and a 2048x2048 scratch is not
# allocated per sprite.
ox, oy: int;

pickc(x, y: int): int
{
	if(rd0 >= 0){
		if((x+y)&1)
			return rd1;
		return rd0;
	}
	return rcol;
}

reflectpt(x, y: real): (real, real)
{
	dx := sbx-sax;
	dy := sby-say;
	d2 := dx*dx+dy*dy;
	if(d2 == 0.0)
		return (2.0*sax-x, 2.0*say-y);
	t := ((x-sax)*dx + (y-say)*dy)/d2;
	px := sax + t*dx;
	py := say + t*dy;
	return (2.0*px-x, 2.0*py-y);
}

# Round half to EVEN, which is what Python's round() does and therefore
# what scripts/tos_extract_sprites.py put in every .bit in icons/temple.
# Limbo's int on a real rounds half AWAY FROM ZERO, and a line stepped
# over integer endpoints lands on exact halves constantly, so the two
# disagreed on twelve pixels of a 527-pixel sprite.
#
# Neither rule is "what TempleOS drew" - its own rasteriser is integer
# arithmetic and rounds neither way.  This picks agreement with the
# shipped assets over agreement with an argument, because a port that
# drew some sprites from vectors and opened others as .bit would
# otherwise render the same sprite two ways.
rnd(v: real): int
{
	f := math->floor(v);
	i := int f;
	d := v - f;
	if(d > 0.5)
		return i+1;
	if(d < 0.5)
		return i;
	if(i & 1)
		return i+1;
	return i;
}

# The coordinates arriving here are canvas coordinates: the element's,
# plus the integer offset that puts the sprite's origin inside the box.
# The rounding has to happen on the ELEMENT coordinate, because rounding
# half to even is not shift-invariant - round(6.5) is 6 and round(6.5+3)
# is 10, not 9 - and the extractor rounds before it offsets.  Subtracting
# an integer from a real is exact at these magnitudes, so this recovers
# the element coordinate rather than approximating it.
putf(x, y: real)
{
	xi := rnd(x - real ox) + ox;
	yi := rnd(y - real oy) + oy;
	setpix(xi, yi, pickc(xi, yi));
	if(symon){
		(rx, ry) := reflectpt(x, y);
		ri := rnd(rx - real ox) + ox;
		rj := rnd(ry - real oy) + oy;
		setpix(ri, rj, pickc(ri, rj));
	}
}

dot(x, y: real)
{
	r := real rthk/2.0;
	if(r <= 0.5){
		putf(x, y);
		return;
	}
	ir := int (r+0.99);
	for(dy := -ir; dy <= ir; dy++)
		for(dx := -ir; dx <= ir; dx++)
			if(real(dx*dx+dy*dy) <= r*r)
				putf(x+real dx, y+real dy);
}

rline(x1, y1, x2, y2: real)
{
	adx := x2-x1; if(adx < 0.0) adx = -adx;
	ady := y2-y1; if(ady < 0.0) ady = -ady;
	steps := int adx;
	if(int ady > steps)
		steps = int ady;
	steps++;
	for(i := 0; i <= steps; i++){
		t := real i/real steps;
		dot(x1+(x2-x1)*t, y1+(y2-y1)*t);
	}
}

pathr(p: array of real, closed: int)
{
	n := len p/2;
	for(i := 0; i < n-1; i++)
		rline(p[2*i], p[2*i+1], p[2*i+2], p[2*i+3]);
	if(closed && n > 1)
		rline(p[2*(n-1)], p[2*n-1], p[0], p[1]);
}

frect(x1, y1, x2, y2: int)
{
	if(x2 < x1){ t := x1; x1 = x2; x2 = t; }
	if(y2 < y1){ t := y1; y1 = y2; y2 = t; }
	for(y := y1; y < y2; y++)
		for(x := x1; x < x2; x++)
			putf(real x, real y);
}

flood(x, y, notcolor: int)
{
	if(x < 0 || x >= rw || y < 0 || y >= rh)
		return;
	target := colval(getpix(x, y));
	inkv := colval(rcol);
	if(!notcolor && target == inkv && rd0 < 0)
		return;
	if(fseen == nil){
		fseen = array[rw*rh] of byte;
		fzero = array[rw*rh] of byte;
		fstack = array[rw*rh] of int;
	}
	fseen[0:] = fzero;
	seen := fseen;
	stack := fstack;
	sp := 0;
	# Mark a pixel seen when it is PUSHED, not when it is popped.  Both
	# fill the same region - nothing writes a pixel but its own pop - but
	# marking at pop lets one pixel be pushed once per neighbour, so the
	# stack needs four times the canvas and this one is exactly the
	# canvas.  It never showed while the canvas was a fixed 680x530 and
	# the fills were small; a canvas cropped to the sprite's own box
	# reaches its edges immediately, and the first sprite whose fill
	# touched one overran the stack.
	seen[y*rw+x] = byte 1;
	stack[sp++] = y*rw+x;
	while(sp > 0){
		pos := stack[--sp];
		px := pos%rw;
		py := pos/rw;
		v := colval(getpix(px, py));
		if(notcolor){
			if(v == inkv)
				continue;
		}else if(v != target)
			continue;
		setpix(px, py, pickc(px, py));
		if(px+1 < rw && seen[pos+1] == byte 0){
			seen[pos+1] = byte 1;
			stack[sp++] = pos+1;
		}
		if(px > 0 && seen[pos-1] == byte 0){
			seen[pos-1] = byte 1;
			stack[sp++] = pos-1;
		}
		if(py+1 < rh && seen[pos+rw] == byte 0){
			seen[pos+rw] = byte 1;
			stack[sp++] = pos+rw;
		}
		if(py > 0 && seen[pos-rw] == byte 0){
			seen[pos-rw] = byte 1;
			stack[sp++] = pos-rw;
		}
	}
}

blot(x, y: int, e: ref Elem)
{
	w := e.a[2];
	h := e.a[3];
	stride := (w+7)&~7;
	for(yy := 0; yy < h; yy++)
		for(xx := 0; xx < w; xx++){
			i := yy*stride+xx;
			if(i >= len e.data)
				continue;
			c := int e.data[i];
			if(c == TRANSP)
				continue;
			setpix(x+xx, y+yy, c&15);
		}
}

# rasterize a string through the temple font (GrPrint cells are 8x8)
textcache(e: ref Elem)
{
	if(e.tras != nil || font == nil || e.txt == "")
		return;
	w := font.width(e.txt);
	if(w < 1)
		w = 1;
	h := font.height;
	timg := display.newimage(Rect((0,0),(w,h)), Draw->GREY8, 0, Draw->Black);
	if(timg == nil)
		return;
	timg.text(Point(0,0), palimg[WHITE], Point(0,0), font, e.txt);
	d := array[w*h] of byte;
	if(timg.readpixels(timg.r, d) < 0)
		return;
	e.tw = w;
	e.th = h;
	e.tras = d;
}

textelem(x, y: int, e: ref Elem)
{
	textcache(e);
	if(e.tras == nil)
		return;
	for(row := 0; row < e.th; row++)
		for(c := 0; c < e.tw; c++)
			if(int e.tras[row*e.tw+c] > 127)
				putf(real(x+c), real(y+row));
	if(e.kind == STEXTBOX){
		p := array[] of {
			real(x-2), real(y-2), real(x+e.tw+1), real(y-2),
			real(x+e.tw+1), real(y+e.th+1), real(x-2), real(y+e.th+1),
		};
		pathr(p, 1);
	}else if(e.kind == STEXTDIAMOND){
		cx := real x + real e.tw/2.0;
		cy := real y + real e.th/2.0;
		hw := real e.tw/2.0 + 8.0;
		hh := real e.th/2.0 + 8.0;
		p := array[] of {
			cx-hw, cy, cx, cy-hh, cx+hw, cy, cx, cy+hh,
		};
		pathr(p, 1);
	}
}

# uniform B-spline sampling (matches the extractor)
bsample(pts: array of int, order, closed: int): array of real
{
	n0 := len pts/3;
	n := n0;
	if(closed)
		n += order;
	cx := array[n] of real;
	cy := array[n] of real;
	for(i := 0; i < n; i++){
		cx[i] = real pts[3*(i%n0)];
		cy[i] = real pts[3*(i%n0)+1];
	}
	if(n < order+1){
		out := array[2*n] of real;
		for(i = 0; i < n; i++){
			out[2*i] = cx[i];
			out[2*i+1] = cy[i];
		}
		return out;
	}
	steps := 16;
	nseg := n-order;
	out := array[2*nseg*(steps+1)] of real;
	k := 0;
	for(seg := 0; seg < nseg; seg++)
		for(s := 0; s <= steps; s++){
			t := real s/real steps;
			b: array of real;
			if(order == 2)
				b = array[] of {
					(1.0-t)*(1.0-t)/2.0,
					(-2.0*t*t+2.0*t+1.0)/2.0,
					t*t/2.0,
				};
			else
				b = array[] of {
					(1.0-t)*(1.0-t)*(1.0-t)/6.0,
					(3.0*t*t*t-6.0*t*t+4.0)/6.0,
					(-3.0*t*t*t+3.0*t*t+3.0*t+1.0)/6.0,
					t*t*t/6.0,
				};
			x := 0.0;
			y := 0.0;
			for(j := 0; j <= order; j++){
				x += b[j]*cx[seg+j];
				y += b[j]*cy[seg+j];
			}
			out[k++] = x;
			out[k++] = y;
		}
	return out[0:k];
}

# polypt 3-bit step decode table: code -> (dx, dy)
stepdx := array[] of {1, 1, 0, -1, -1, -1, 0, 1};
stepdy := array[] of {0, 1, 1, 1, 0, -1, -1, -1};

polyptdraw(x, y: int, e: ref Elem)
{
	dot(real x, real y);
	num := e.a[0];
	for(i := 0; i < num; i++){
		bit := i*3;
		v := 0;
		for(b := 0; b < 3; b++){
			bi := bit+b;
			if(bi>>3 < len e.data)
				v |= ((int e.data[bi>>3] >> (bi&7)) & 1) << b;
		}
		x += stepdx[v];
		y += stepdy[v];
		dot(real x, real y);
	}
}

drawelem(e: ref Elem)
{
	x := ox + rsx;
	y := oy + rsy;
	case e.kind {
	SCOLOR =>
		rcol = e.a[0];
		rd0 = -1;
	SDITHER =>
		rd0 = e.a[0];
		rd1 = e.a[1];
	STHICK =>
		rthk = e.a[0];
		if(rthk < 1)
			rthk = 1;
	SSHIFT =>
		rsx += e.a[0];
		rsy += e.a[1];
	SPLANARSYM =>
		if(e.a[0] == e.a[2] && e.a[1] == e.a[3])
			symon = 0;
		else{
			sax = real(x+e.a[0]);
			say = real(y+e.a[1]);
			sbx = real(x+e.a[2]);
			sby = real(y+e.a[3]);
			symon = 1;
		}
	SPT =>
		dot(real(x+e.a[0]), real(y+e.a[1]));
	SLINE =>
		rline(real(x+e.a[0]), real(y+e.a[1]), real(x+e.a[2]), real(y+e.a[3]));
	SARROW =>
		x1 := real(x+e.a[0]); y1 := real(y+e.a[1]);
		x2 := real(x+e.a[2]); y2 := real(y+e.a[3]);
		rline(x1, y1, x2, y2);
		ang := math->atan2(y2-y1, x2-x1);
		rline(x2, y2, x2+6.0*math->cos(ang+2.6), y2+6.0*math->sin(ang+2.6));
		rline(x2, y2, x2+6.0*math->cos(ang-2.6), y2+6.0*math->sin(ang-2.6));
	SRECT =>
		frect(x+e.a[0], y+e.a[1], x+e.a[2], y+e.a[3]);
	SROTRECT =>
		cx := real(x+e.a[0]); cy := real(y+e.a[1]);
		x2 := real(x+e.a[2]); y2 := real(y+e.a[3]);
		c := math->cos(e.ang);
		s := math->sin(e.ang);
		p := array[8] of real;
		px := array[] of {cx, x2, x2, cx};
		py := array[] of {cy, cy, y2, y2};
		for(i := 0; i < 4; i++){
			dx := px[i]-cx;
			dy := py[i]-cy;
			p[2*i] = cx + dx*c - dy*s;
			p[2*i+1] = cy + dx*s + dy*c;
		}
		pathr(p, 1);
	SCIRCLE =>
		cx := real(x+e.a[0]); cy := real(y+e.a[1]);
		r := real e.a[2];
		ar := r; if(ar < 0.0) ar = -ar;
		n := int (2.0*Math->Pi*ar);
		if(n < 12)
			n = 12;
		p := array[2*n] of real;
		for(i := 0; i < n; i++){
			t := 2.0*Math->Pi*real i/real n;
			p[2*i] = cx + r*math->cos(t);
			p[2*i+1] = cy + r*math->sin(t);
		}
		pathr(p, 1);
	SELLIPSE =>
		cx := real(x+e.a[0]); cy := real(y+e.a[1]);
		w := real e.a[2]; h := real e.a[3];
		c := math->cos(e.ang);
		s := math->sin(e.ang);
		aw := w; if(aw < 0.0) aw = -aw;
		ah := h; if(ah < 0.0) ah = -ah;
		n := 2*(int aw + int ah);
		if(n < 12)
			n = 12;
		p := array[2*n] of real;
		for(i := 0; i < n; i++){
			t := 2.0*Math->Pi*real i/real n;
			ex := w*math->cos(t);
			ey := h*math->sin(t);
			p[2*i] = cx + ex*c - ey*s;
			p[2*i+1] = cy + ex*s + ey*c;
		}
		pathr(p, 1);
	SPOLYGON =>
		cx := real(x+e.a[0]); cy := real(y+e.a[1]);
		w := real e.a[2]; h := real e.a[3];
		nside := e.a[4];
		if(nside < 2)
			nside = 2;
		p := array[2*nside] of real;
		for(i := 0; i < nside; i++){
			t := e.ang + 2.0*Math->Pi*real i/real nside;
			p[2*i] = cx + w*math->cos(t);
			p[2*i+1] = cy + h*math->sin(t);
		}
		pathr(p, 1);
	SPOLYLINE =>
		n := len e.pts/2;
		p := array[2*n] of real;
		for(i := 0; i < n; i++){
			p[2*i] = real(x+e.pts[2*i]);
			p[2*i+1] = real(y+e.pts[2*i+1]);
		}
		pathr(p, 0);
	SPOLYPT =>
		polyptdraw(x+e.a[1], y+e.a[2], e);
	SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
		order := 2;
		if(e.kind == SBSPLINE3 || e.kind == SBSPLINE3C)
			order = 3;
		closed := e.kind == SBSPLINE2C || e.kind == SBSPLINE3C;
		p := bsample(e.pts, order, closed);
		for(i := 0; i < len p; i += 2){
			p[i] += real x;
			p[i+1] += real y;
		}
		pathr(p, 0);
	SFLOOD =>
		flood(x+e.a[0], y+e.a[1], 0);
	SFLOODNOT =>
		flood(x+e.a[0], y+e.a[1], 1);
	SBITMAP =>
		blot(x+e.a[0], y+e.a[1], e);
	STEXT or STEXTBOX or STEXTDIAMOND =>
		textelem(x+e.a[0], y+e.a[1], e);
	}
}


kindof(s: string): int
{
	for(i := 1; i < NKIND; i++)
		if(names[i] == s)
			return i;
	return -1;
}

hexenc(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%2.2x", int d[i]);
	return s;
}

hexdec(s: string): array of byte
{
	d := array[len s/2] of byte;
	for(i := 0; i < len d; i++){
		v := 0;
		for(j := 0; j < 2; j++){
			c := s[2*i+j];
			if(c >= '0' && c <= '9')
				v = v*16 + c-'0';
			else if(c >= 'a' && c <= 'f')
				v = v*16 + 10+c-'a';
			else if(c >= 'A' && c <= 'F')
				v = v*16 + 10+c-'A';
			else
				return nil;
		}
		d[i] = byte v;
	}
	return d;
}

qstr(s: string): string
{
	o := "'";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'\\' =>	o += "\\\\";
		'\'' =>	o += "\\'";
		'\n' =>	o += "\\n";
		'\t' =>	o += "\\t";
		* =>	o[len o] = c;
		}
	}
	return o+"'";
}

unq(s: string): string
{
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	if(len s >= 2 && (s[0] == '\'' || s[0] == '"') && s[len s-1] == s[0])
		s = s[1:len s-1];
	o := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '\\' && i+1 < len s){
			i++;
			case s[i] {
			'n' =>	o[len o] = '\n';
			't' =>	o[len o] = '\t';
			'x' =>
				v := 0;
				for(j := 0; j < 2 && i+1 < len s; j++){
					h := s[i+1];
					hv := -1;
					if(h >= '0' && h <= '9')
						hv = h-'0';
					else if(h >= 'a' && h <= 'f')
						hv = 10+h-'a';
					else if(h >= 'A' && h <= 'F')
						hv = 10+h-'A';
					if(hv < 0)
						break;
					v = v*16+hv;
					i++;
				}
				o[len o] = v;
			* =>	o[len o] = s[i];
			}
		}else
			o[len o] = c;
	}
	return o;
}

elemline(e: ref Elem): string
{
	nm := names[e.kind];
	case e.kind {
	SCOLOR or STHICK =>
		return sys->sprint("%s %d", nm, e.a[0]);
	SDITHER =>
		return sys->sprint("%s %d %d", nm, e.a[0], e.a[1]);
	SPLANARSYM or SLINE or SARROW or SRECT =>
		return sys->sprint("%s %d %d %d %d", nm, e.a[0], e.a[1], e.a[2], e.a[3]);
	SROTRECT =>
		return sys->sprint("%s %d %d %d %d %g", nm, e.a[0], e.a[1], e.a[2], e.a[3], e.ang);
	SSHIFT or SPT or SFLOOD or SFLOODNOT =>
		return sys->sprint("%s %d %d", nm, e.a[0], e.a[1]);
	SCIRCLE =>
		return sys->sprint("%s %d %d %d", nm, e.a[0], e.a[1], e.a[2]);
	SELLIPSE =>
		return sys->sprint("%s %d %d %d %d %g", nm, e.a[0], e.a[1], e.a[2], e.a[3], e.ang);
	SPOLYGON =>
		return sys->sprint("%s %d %d %d %d %g %d", nm, e.a[0], e.a[1], e.a[2], e.a[3], e.ang, e.a[4]);
	SPOLYLINE =>
		s := sys->sprint("%s %d", nm, len e.pts/2);
		for(i := 0; i < len e.pts; i++)
			s += sys->sprint(" %d", e.pts[i]);
		return s;
	SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
		s := sys->sprint("%s %d", nm, len e.pts/3);
		for(i := 0; i < len e.pts; i++)
			s += sys->sprint(" %d", e.pts[i]);
		return s;
	SPOLYPT =>
		n := (e.a[0]*3+7)>>3;
		d := e.data;
		if(d == nil)
			d = array[0] of byte;
		if(n < len d)
			d = d[0:n];
		return sys->sprint("%s %d %d %d %s", nm, e.a[0], e.a[1], e.a[2], hexenc(d));
	SBITMAP =>
		return sys->sprint("%s %d %d %d %d %s", nm, e.a[0], e.a[1], e.a[2], e.a[3], hexenc(e.data));
	SMESH or SSHIFTMESH =>
		return sys->sprint("%s %d %d", nm, e.a[0], e.a[1]);
	STRANSON or STRANSOFF =>
		return nm;
	STEXT or STEXTBOX or STEXTDIAMOND =>
		return sys->sprint("%s %d %d %s", nm, e.a[0], e.a[1], qstr(e.txt));
	}
	return nm;
}

parseline(line: string): (ref Elem, string)
{
	(n, toks) := sys->tokenize(line, " \t\r");
	if(n == 0)
		return (nil, "");
	k := kindof(hd toks);
	if(k < 0)
		return (nil, "unknown element "+hd toks);
	toks = tl toks;
	args := array[n-1] of string;
	i := 0;
	for(; toks != nil; toks = tl toks)
		args[i++] = hd toks;
	case k {
	SCOLOR or STHICK =>
		if(len args < 1)
			return (nil, "short "+names[k]);
		e := mkelem(k, 1);
		e.a[0] = int args[0];
		return (e, "");
	SDITHER =>
		if(len args < 2)
			return (nil, "short dither");
		e := mkelem(k, 2);
		e.a[0] = int args[0];
		e.a[1] = int args[1];
		return (e, "");
	SPLANARSYM or SLINE or SARROW or SRECT =>
		if(len args < 4)
			return (nil, "short "+names[k]);
		e := mkelem(k, 4);
		for(j := 0; j < 4; j++)
			e.a[j] = int args[j];
		return (e, "");
	SROTRECT =>
		if(len args < 5)
			return (nil, "short rotrect");
		e := mkelem(k, 4);
		for(j := 0; j < 4; j++)
			e.a[j] = int args[j];
		e.ang = real args[4];
		return (e, "");
	SSHIFT or SPT or SFLOOD or SFLOODNOT =>
		if(len args < 2)
			return (nil, "short "+names[k]);
		e := mkelem(k, 2);
		e.a[0] = int args[0];
		e.a[1] = int args[1];
		return (e, "");
	SCIRCLE =>
		if(len args < 3)
			return (nil, "short circle");
		e := mkelem(k, 3);
		for(j := 0; j < 3; j++)
			e.a[j] = int args[j];
		return (e, "");
	SELLIPSE =>
		if(len args < 5)
			return (nil, "short ellipse");
		e := mkelem(k, 4);
		for(j := 0; j < 4; j++)
			e.a[j] = int args[j];
		e.ang = real args[4];
		return (e, "");
	SPOLYGON =>
		if(len args < 6)
			return (nil, "short polygon");
		e := mkelem(k, 5);
		for(j := 0; j < 4; j++)
			e.a[j] = int args[j];
		e.ang = real args[4];
		e.a[4] = int args[5];
		return (e, "");
	SPOLYLINE =>
		if(len args < 1)
			return (nil, "short polyline");
		np := int args[0];
		if(np < 0 || len args < 1+2*np)
			return (nil, "short polyline");
		e := mkelem(k, 0);
		e.pts = array[2*np] of int;
		for(j := 0; j < 2*np; j++)
			e.pts[j] = int args[1+j];
		return (e, "");
	SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
		if(len args < 1)
			return (nil, "short bspline");
		np := int args[0];
		if(np < 0 || len args < 1+3*np)
			return (nil, "short bspline");
		e := mkelem(k, 0);
		e.pts = array[3*np] of int;
		for(j := 0; j < 3*np; j++)
			e.pts[j] = int args[1+j];
		return (e, "");
	SPOLYPT =>
		if(len args < 3)
			return (nil, "short polypt");
		e := mkelem(k, 3);
		e.a[0] = int args[0];
		e.a[1] = int args[1];
		e.a[2] = int args[2];
		if(len args >= 4)
			e.data = hexdec(args[3]);
		if(e.data == nil)
			e.data = array[(e.a[0]*3+7)>>3] of {* => byte 0};
		return (e, "");
	SBITMAP =>
		if(len args < 5)
			return (nil, "short bitmap");
		e := mkelem(k, 4);
		for(j := 0; j < 4; j++)
			e.a[j] = int args[j];
		e.data = hexdec(args[4]);
		if(e.data == nil)
			return (nil, "bad bitmap hex");
		return (e, "");
	SMESH or SSHIFTMESH =>
		e := mkelem(k, 2);
		if(len args >= 2){
			e.a[0] = int args[0];
			e.a[1] = int args[1];
		}
		return (e, "");
	STRANSON or STRANSOFF =>
		return (mkelem(k, 0), "");
	STEXT or STEXTBOX or STEXTDIAMOND =>
		if(len args < 2)
			return (nil, "short text");
		e := mkelem(k, 2);
		e.a[0] = int args[0];
		e.a[1] = int args[1];
		# the string is the rest of the raw line after the third field
		p := 0;
		fields := 0;
		while(p < len line && fields < 3){
			while(p < len line && (line[p] == ' ' || line[p] == '\t'))
				p++;
			while(p < len line && line[p] != ' ' && line[p] != '\t')
				p++;
			fields++;
		}
		e.txt = unq(line[p:]);
		return (e, "");
	}
	return (nil, "unhandled "+names[k]);
}

parselist(body: string): (array of ref Elem, int, string)
{
	(nil, lines) := sys->tokenize(body, "\n");
	out := array[64] of ref Elem;
	n := 0;
	for(; lines != nil; lines = tl lines){
		(e, err) := parseline(hd lines);
		if(err != "")
			return (nil, 0, err);
		if(e == nil)
			continue;
		if(n == len out){
			na := array[2*len out] of ref Elem;
			na[0:] = out[0:n];
			out = na;
		}
		out[n++] = e;
	}
	return (out, n, "");
}




# ---------- transform (SpriteTransformQue) ----------

# The three-bit step codes, indexed (dy+1)*3+(dx+1); -1 is "no move".
enccode := array[] of {5, 6, 7, 4, -1, 0, 3, 2, 1};

polyptabs(e: ref Elem): array of int
{
	out := array[2*(e.a[0]+1)] of int;
	x := e.a[1];
	y := e.a[2];
	out[0] = x;
	out[1] = y;
	for(i := 0; i < e.a[0]; i++){
		bit := i*3;
		v := 0;
		for(b := 0; b < 3; b++){
			bi := bit+b;
			if(bi>>3 < len e.data)
				v |= ((int e.data[bi>>3] >> (bi&7)) & 1) << b;
		}
		x += stepdx[v];
		y += stepdy[v];
		out[2*(i+1)] = x;
		out[2*(i+1)+1] = y;
	}
	return out;
}

walkappend(e: ref Elem, x2, y2, lx, ly: int): (int, int)
{
	adx := x2-lx; if(adx < 0) adx = -adx;
	ady := y2-ly; if(ady < 0) ady = -ady;
	steps := adx;
	if(ady > steps)
		steps = ady;
	if(steps == 0)
		return (lx, ly);
	for(i := 1; i <= steps; i++){
		nx := lx + (x2-lx)*i/steps;
		ny := ly + (y2-ly)*i/steps;
		dx := nx-lx;
		dy := ny-ly;
		if(dx < -1) dx = -1;
		if(dx > 1) dx = 1;
		if(dy < -1) dy = -1;
		if(dy > 1) dy = 1;
		code := enccode[(dy+1)*3+(dx+1)];
		if(code < 0)
			continue;
		num := e.a[0];
		need := (num*3+3+7)>>3;
		if(e.data == nil || need > len e.data){
			nd := array[need+64] of {* => byte 0};
			if(e.data != nil)
				nd[0:] = e.data;
			e.data = nd;
		}
		bit := num*3;
		for(b := 0; b < 3; b++)
			if(code & (1<<b))
				e.data[(bit+b)>>3] |= byte (1<<((bit+b)&7));
		e.a[0] = num+1;
		lx += dx;
		ly += dy;
	}
	return (lx, ly);
}

# Rounding here is Limbo's int, half away from zero, and NOT the
# half-to-even the rasteriser uses.  The rasteriser's rule is set by the
# .bit files it has to match; nothing constrains this one, and this is
# the rule temple/spriteedit(1)'s Transform Selected has always used, so
# a transform means the same thing in the editor and here.
xpt(x, y: int, c, s: real): (int, int)
{
	return (int (real x*c - real y*s), int (real x*s + real y*c));
}

transform(elems: array of ref Elem, deg, scale: real): array of ref Elem
{
	if(elems == nil)
		return nil;
	out := array[len elems] of ref Elem;
	for(i := 0; i < len elems; i++)
		out[i] = transformelem(elems[i], deg, scale);
	return out;
}

transformelem(e: ref Elem, deg, scale: real): ref Elem
{
	if(e == nil)
		return nil;
	init();
	th := deg*Math->Pi/180.0;
	c := scale*math->cos(th);
	s := scale*math->sin(th);
	k := scale;
	n := copyelem(e);
	case n.kind {
	STHICK =>
		n.a[0] = int (real n.a[0]*k);
		if(n.a[0] < 1)
			n.a[0] = 1;
	SLINE or SARROW or SPLANARSYM =>
		(n.a[0], n.a[1]) = xpt(n.a[0], n.a[1], c, s);
		(n.a[2], n.a[3]) = xpt(n.a[2], n.a[3], c, s);
	SRECT or SROTRECT =>
		# TempleOS promotes a rect to a rotated rect under transform
		w := int (real(n.a[2]-n.a[0])*k);
		h := int (real(n.a[3]-n.a[1])*k);
		(nx, ny) := xpt(n.a[0], n.a[1], c, s);
		r := mkelem(SROTRECT, 4);
		r.a[0] = nx;
		r.a[1] = ny;
		r.a[2] = nx+w;
		r.a[3] = ny+h;
		r.ang = n.ang + th;
		r.tag = n.tag;
		return r;
	SCIRCLE =>
		(n.a[0], n.a[1]) = xpt(n.a[0], n.a[1], c, s);
		n.a[2] = int (real n.a[2]*k);
	SELLIPSE or SPOLYGON =>
		(n.a[0], n.a[1]) = xpt(n.a[0], n.a[1], c, s);
		n.a[2] = int (real n.a[2]*k);
		n.a[3] = int (real n.a[3]*k);
		n.ang = n.ang + th;
	SPT or SFLOOD or SFLOODNOT or STEXT or STEXTBOX or
	STEXTDIAMOND or SBITMAP =>
		(n.a[0], n.a[1]) = xpt(n.a[0], n.a[1], c, s);
	SPOLYLINE =>
		for(i := 0; i < len n.pts; i += 2)
			(n.pts[i], n.pts[i+1]) = xpt(n.pts[i], n.pts[i+1], c, s);
	SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
		for(i := 0; i < len n.pts; i += 3)
			(n.pts[i], n.pts[i+1]) = xpt(n.pts[i], n.pts[i+1], c, s);
	SPOLYPT =>
		# re-walk the transformed path, as SpriteTransformQue does
		p := polyptabs(n);
		r := mkelem(SPOLYPT, 3);
		r.tag = n.tag;
		(r.a[1], r.a[2]) = xpt(p[0], p[1], c, s);
		lx := r.a[1];
		ly := r.a[2];
		for(i := 2; i < len p; i += 2){
			(nx, ny) := xpt(p[i], p[i+1], c, s);
			(lx, ly) = walkappend(r, nx, ny, lx, ly);
		}
		return r;
	}
	return n;
}

Sprite.transformed(s: self ref Sprite, deg, scale: real): ref Sprite
{
	t := ref Sprite;
	t.elems = transform(s.elems, deg, scale);
	return t;
}

# ---------- the public face ----------

read(path: string): (ref Sprite, string)
{
	init();
	if(bufio == nil)
		return (nil, "cannot load bufio");
	fd := bufio->open(path, Bufio->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", path));
	body := "";
	for(;;){
		l := fd.gets('\n');
		if(l == nil)
			break;
		body += l;
	}
	return parse(body);
}

parse(text: string): (ref Sprite, string)
{
	init();
	(es, n, err) := parselist(text);
	if(err != "")
		return (nil, err);
	# parselist grows its array in powers of two and reports the count
	# separately; the tail is nil, and handing that out whole is a nil
	# dereference waiting in every caller's loop.
	out := array[n] of ref Elem;
	for(i := 0; i < n; i++)
		out[i] = es[i];
	return (ref Sprite(out), nil);
}

# The box a sprite occupies, from the elements' nominal extents with the
# pen's half-width as a margin - transcribed from bounds() in
# scripts/tos_extract_sprites.py, which is what set the rect of every
# .bit in icons/temple.  It is deliberately NOT the box the pixels came
# out in: a line's rasterisation can fall a pixel short of its pen's
# reach, and taking the box from the pixels made every sprite come out
# one row and one column smaller than the .bit beside it.
Sprite.bounds(s: self ref Sprite): (Rect, int)
{
	return elembounds(s.elems);
}

# The same, as a plain function.  Calling one self method from another
# inside the module that implements them compiles to a call through the
# caller's module reference, which here is nil - "module not loaded" at
# run time.  Everything internal goes through this.
elembounds(elems: array of ref Elem): (Rect, int)
{
	x0 := 1000000; y0 := 1000000;
	x1 := -1000000; y1 := -1000000;
	sx := 0; sy := 0;
	thick := 1;
	have := 0;
	symon2 := 0;
	ax, ay, bx, by: real;
	for(i := 0; i < len elems; i++){
		e := elems[i];
		m := thick/2 + 1;
		px, py, pm: array of int;
		case e.kind {
		STHICK =>
			thick = e.a[0];
			continue;
		SSHIFT =>
			sx += e.a[0];
			sy += e.a[1];
			continue;
		SPLANARSYM =>
			ax = real (e.a[0]+sx); ay = real (e.a[1]+sy);
			bx = real (e.a[2]+sx); by = real (e.a[3]+sy);
			symon2 = 1;
			continue;
		SPT or SFLOOD or SFLOODNOT =>
			px = array[] of {e.a[0]+sx};
			py = array[] of {e.a[1]+sy};
			pm = array[] of {m};
		SLINE or SRECT or SARROW =>
			px = array[] of {e.a[0]+sx, e.a[2]+sx};
			py = array[] of {e.a[1]+sy, e.a[3]+sy};
			pm = array[] of {m, m};
		SROTRECT =>
			dx := real (e.a[2]-e.a[0]);
			dy := real (e.a[3]-e.a[1]);
			r := int math->sqrt(dx*dx+dy*dy) + 1;
			px = array[] of {e.a[0]+sx};
			py = array[] of {e.a[1]+sy};
			pm = array[] of {r+m};
		SCIRCLE =>
			r := e.a[2];
			if(r < 0)
				r = -r;
			px = array[] of {e.a[0]+sx};
			py = array[] of {e.a[1]+sy};
			pm = array[] of {r+m};
		SELLIPSE or SPOLYGON =>
			r := e.a[2];
			if(r < 0)
				r = -r;
			r2 := e.a[3];
			if(r2 < 0)
				r2 = -r2;
			if(r2 > r)
				r = r2;
			px = array[] of {e.a[0]+sx};
			py = array[] of {e.a[1]+sy};
			pm = array[] of {r+m};
		SPOLYLINE =>
			n := len e.pts/2;
			px = array[n] of int;
			py = array[n] of int;
			pm = array[n] of int;
			for(j := 0; j < n; j++){
				px[j] = e.pts[2*j]+sx;
				py[j] = e.pts[2*j+1]+sy;
				pm[j] = m;
			}
		SPOLYPT =>
			px = array[] of {e.a[1]+sx};
			py = array[] of {e.a[2]+sy};
			pm = array[] of {e.a[0]+m};
		SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
			n := len e.pts/3;
			px = array[n] of int;
			py = array[n] of int;
			pm = array[n] of int;
			for(j := 0; j < n; j++){
				px[j] = e.pts[3*j]+sx;
				py[j] = e.pts[3*j+1]+sy;
				pm[j] = m;
			}
		SBITMAP =>
			px = array[] of {e.a[0]+sx, e.a[0]+e.a[2]+sx};
			py = array[] of {e.a[1]+sy, e.a[1]+e.a[3]+sy};
			pm = array[] of {0, 0};
		STEXT or STEXTBOX or STEXTDIAMOND =>
			px = array[] of {e.a[0]+sx, e.a[0]+8*len e.txt+sx};
			py = array[] of {e.a[1]+sy, e.a[1]+8+sy};
			pm = array[] of {0, 0};
		* =>
			continue;
		}
		for(j := 0; j < len px; j++){
			(x0, y0, x1, y1) = extend(x0, y0, x1, y1,
				px[j], py[j], pm[j]);
			if(symon2){
				(rx, ry) := reflect(real px[j], real py[j],
					ax, ay, bx, by);
				(x0, y0, x1, y1) = extend(x0, y0, x1, y1,
					int rx, int ry, pm[j]);
			}
			have = 1;
		}
	}
	if(!have)
		return (Rect((0,0),(0,0)), 0);
	return (Rect((x0,y0),(x1,y1)), 1);
}

extend(x0, y0, x1, y1, x, y, m: int): (int, int, int, int)
{
	if(x-m < x0) x0 = x-m;
	if(y-m < y0) y0 = y-m;
	if(x+m+1 > x1) x1 = x+m+1;
	if(y+m+1 > y1) y1 = y+m+1;
	return (x0, y0, x1, y1);
}

reflect(x, y, ax, ay, bx, by: real): (real, real)
{
	dx := bx-ax;
	dy := by-ay;
	d2 := dx*dx+dy*dy;
	if(d2 == 0.0)
		return (2.0*ax-x, 2.0*ay-y);
	t := ((x-ax)*dx + (y-ay)*dy)/d2;
	return (2.0*(ax+t*dx)-x, 2.0*(ay+t*dy)-y);
}

Sprite.pixels(s: self ref Sprite, d: ref Display): (array of byte, Rect)
{
	return spritepixels(s.elems, d);
}

spritepixels(elems: array of ref Elem, d: ref Display): (array of byte, Rect)
{
	init();
	setdisplay(d);
	(r, okb) := elembounds(elems);
	# Rect.dx() is a Draw method and Draw is not there in a headless
	# emu; the arithmetic is done by hand so a sprite can be measured
	# and rasterised to palette indices with no display at all, which
	# is what makes vspritetest(1) able to say anything under emu-g.
	w := r.max.x - r.min.x;
	h := r.max.y - r.min.y;
	if(!okb || w < 1 || h < 1)
		return (nil, Rect((0,0),(0,0)));
	return (canvas(elems, w, h, -r.min.x, -r.min.y, d), r);
}

canvas(elems: array of ref Elem, w, h, cx, cy: int, d: ref Display): array of byte
{
	init();
	setdisplay(d);
	if(w < 1 || h < 1)
		return nil;
	rw = w;
	rh = h;
	ox = cx;
	oy = cy;
	rbuf = array[rw*rh] of { * => byte UNDRAWN };
	fseen = nil;
	fzero = nil;
	fstack = nil;
	rcol = 0; rd0 = -1; rd1 = 0; rthk = 1;
	rsx = 0; rsy = 0;
	symon = 0;
	for(i := 0; i < len elems; i++)
		if(elems[i] != nil)
			drawelem(elems[i]);
	# What the canvas holds is already the answer, bar one index: a
	# pixel painted TRANSP is opaque white on the canvas, so it comes
	# out as whatever WHITE quantises to, the way the RGBA canvas made
	# it come out.
	out := array[w*h] of { * => byte TRANSP };
	tw := byte nearest(int 16rFFFFFF00);
	for(i = 0; i < w*h; i++){
		v := rbuf[i];
		if(v == byte UNDRAWN)
			continue;
		if(v == byte TRANSP)
			v = tw;
		out[i] = v;
	}
	# Let the canvas go: some of these are large and a caller may hold
	# the result for a long time.
	rbuf = nil;
	fseen = nil;
	fzero = nil;
	fstack = nil;
	return out;
}

# Which palette index a rendered pixel is.  Dither and flood produce only
# palette colours, so this is a lookup rather than a quantisation - but
# it is written as a nearest search so a colour that is not one of the
# sixteen (a caller that set a register, say) still lands somewhere sane.
nearest(v: int): int
{
	r := (v>>24)&255;
	g := (v>>16)&255;
	b := (v>>8)&255;
	best := 0;
	bd := 1<<30;
	for(i := 0; i < Grpalette->COLORS; i++){
		pr := (pal[i]>>24)&255;
		pg := (pal[i]>>16)&255;
		pb := (pal[i]>>8)&255;
		dd := (r-pr)*(r-pr) + (g-pg)*(g-pg) + (b-pb)*(b-pb);
		if(dd < bd){
			bd = dd;
			best = i;
		}
	}
	return best;
}

Sprite.raster(s: self ref Sprite, d: ref Display): (ref Image, ref Image, Rect)
{
	(px, r) := spritepixels(s.elems, d);
	if(px == nil)
		return (nil, nil, r);
	w := r.max.x - r.min.x;
	h := r.max.y - r.min.y;
	img := d.newimage(Rect((0,0),(w,h)), Draw->RGB24, 0, Draw->Black);
	msk := d.newimage(Rect((0,0),(w,h)), Draw->GREY1, 0, Draw->Black);
	if(img == nil || msk == nil)
		return (nil, nil, r);
	ib := array[w*h*3] of { * => byte 0 };
	mpl := (w+7)/8;
	mb := array[mpl*h] of { * => byte 0 };
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			c := int px[y*w+x];
			if(c == TRANSP)
				continue;
			v := pal[c&15];
			ib[(y*w+x)*3] = byte ((v>>8)&16rFF);	# blue
			ib[(y*w+x)*3+1] = byte ((v>>16)&16rFF);	# green
			ib[(y*w+x)*3+2] = byte ((v>>24)&16rFF);	# red
			mb[y*mpl + (x>>3)] |= byte (16r80 >> (x&7));
		}
	img.writepixels(img.r, ib);
	msk.writepixels(msk.r, mb);
	return (img, msk, r);
}
