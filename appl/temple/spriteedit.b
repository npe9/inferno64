implement Spriteedit;

# TempleOS DolDoc sprite editor (Adam/Gr/SpriteEd.HC, SpriteMain.HC,
# SpriteSideBar.HC, SpriteCode.HC), rebuilt as a vector ELEMENT-LIST editor.
# A sprite is an ordered queue of drawing elements (color, dither, thick,
# planar symmetry, points, lines, arrows, rects, circles, ellipses, regular
# polygons, polylines, poly-points, B-splines, flood fills, bitmaps, text)
# replayed in order, exactly as TempleOS replays a CSprite through the DC.
#
# On disk an element is one text line, the same vocabulary written by
# scripts/tos_extract_sprites.py into lib/temple/sprites/*.spr, so the two
# tools compose:  "color 4", "line 2 -15 -1 -4", "polygon 0 0 20 20 0.0 6" ...
# Sprites live either bare (whole file is the list, e.g. a .spr file) or
# embedded in a host text document between ".SPRITE name" and ".ENDSPRITE",
# echoing DolDoc's sprites-inside-documents.  Legacy raster ".SPRITE name w h
# r8g8b8a8" blocks load as a single bitmap element.  ".MESH" blocks still get
# the 3D mesh editor (SpriteMeshEd's echo).
#
# GAP: the sprite is edited over a plain white page, not a live DolDoc
#	document; control-point handles are drawn solid, not blinking.
# GAP: "mesh"/"shiftmesh" ELEMENTS inside a sprite are inert placeholders
#	(vertex data is edited via a .MESH block instead); the mesh editor has
#	no polygon/fence/prism tools.
# GAP: Transform Selected offers rotate/scale (exact for every 2D element,
#	with TempleOS's rect->rotated-rect and promotion rules) rather than the
#	full 4x4 matrix popup; bitmap elements are moved, not resampled.
# GAP: screen capture captures the editor's own canvas (the analog of the
#	document under the sprite), not the host screen; Insert Clip is
#	"Insert Sprite File" (no system clipboard of sprites exists here).

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
include "grpalette.m";
	grpal: Grpalette;

Spriteedit: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# element kinds, numerically matching TempleOS SPT_* / tos_extract_sprites.py
SEND, SCOLOR, SDITHER, STHICK, SPLANARSYM,
STRANSON, STRANSOFF, SSHIFT, SPT, SPOLYPT,
SLINE, SPOLYLINE, SRECT, SROTRECT, SCIRCLE,
SELLIPSE, SPOLYGON, SBSPLINE2, SBSPLINE2C,
SBSPLINE3, SBSPLINE3C, SFLOOD, SFLOODNOT,
SBITMAP, SMESH, SSHIFTMESH, SARROW, STEXT,
STEXTBOX, STEXTDIAMOND: con iota;
NKIND: con STEXTDIAMOND+1;

TRANSP: con 255;

names := array[] of {
	"end", "color", "dither", "thick", "planarsym",
	"transform_on", "transform_off", "shift", "pt", "polypt",
	"line", "polyline", "rect", "rotrect", "circle",
	"ellipse", "polygon", "bspline2", "bspline2closed",
	"bspline3", "bspline3closed", "floodfill", "floodfillnot",
	"bitmap", "mesh", "shiftmesh", "arrow", "text",
	"textbox", "textdiamond",
};

Elem: adt {
	kind: int;
	a: array of int;		# fixed args (positions, sizes, colors)
	ang: real;			# rotrect/ellipse/polygon
	pts: array of int;		# polyline (2/pt) and bsplines (3/pt)
	data: array of byte;		# bitmap pixels / polypt step codes
	txt: string;			# text family
	sel: int;
	tw, th: int;			# cached text raster
	tras: array of byte;
};

# editor modes
Mmain, Medit, Mtool, Mtext, Mnum, Mfile, Mxform,
Mpoints, Mshiftsel, Msetorigin, Msuborigin, Mbitmap: con iota;

# pseudo-tools (beyond element kinds)
TCAPTURE: con 100;
TCAPTURET: con 101;
TBITMAPED: con 102;

# palette pick destinations
Pnone, Pcolor, Pdither0, Pdither1, Pbgcolor: con iota;

# numeric prompt targets
Nsides, Nthick: con iota;

# points-mode variants (order mirrors SPED_*: even=point, odd=rect)
PMsel, PMselrect, PMunsel, PMunselrect, PMshift, PMshiftrect: con iota;

W: con 900;
H: con 560;
Topb: con 26;			# top bar height
Sw: con 214;			# sidebar width
Cw: con 680;			# canvas raster size
Ch: con 530;

win: ref Window;
display: ref Display;
font: ref Font;
fonth := 10;

# the exact TempleOS 16-color palette (index = TempleOS color)
pal: array of int;
BLACK: con 0; PURPLE: con 5; LTGRAY: con 7; DKGRAY: con 8;
LTBLUE: con 9; LTRED: con 12; YELLOW: con 14; WHITE: con 15;

palimg: array of ref Image;
cachev: array of int;
cachei: array of ref Image;
ncache := 0;

canvasimg: ref Image;
blank, work: array of byte;
canr: Rect;			# canvas position in window coords

elems: array of ref Elem;
ne := 0;
cur := 0;			# insertion point (elements before it set the DC state)
snap: array of ref Elem;	# deep copy at load, for Abort Sprite
nsnap := 0;
wrote := 0;			# file written this session

mode := Mmain;
tool := 0;
phase := 0;
pickfor := Pnone;
sides := 6;
pendbg := 0;
numfor := 0;
pbuf := "";
texttool := STEXT;

pv: ref Elem;			# rubber-band preview element, replayed at cur
pvon := 0;
ax := 0; ay := 0;		# drag anchor, element coords
a2 := 0.0;			# ellipse/polygon base angle
capx0, capy0, capx1, capy1: int;	# capture rect, canvas coords
capon := 0;
prevb := 0;
mcx := 0; mcy := 0;		# last mouse pos, canvas coords

listtop := 0;
lastcur := -1;		# auto-scroll the list only when the insertion point moves
listr: Rect;
palr: Rect;

status := "";
path := "/tmp/sprite.spr";
name := "sprite";
prefix, suffix: string;
bare := 0;
origtext := "";			# file content at load (for Abort)
hadfile := 0;

# replay state
fseen, fzero: array of byte;	# flood-fill scratch
fstack: array of int;
rcol := 0; rd0 := -1; rd1 := 0; rthk := 1;
rsx := 0; rsy := 0;
symon := 0;
sax, say, sbx, sby: real;
rbuf: array of byte;

# points mode
cpe, cpw: array of int;		# element index, point selector
cpsel: array of int;
ncp := 0;
pmode := PMsel;
lastcx := 0; lastcy := 0;
dragging := 0;

# bitmap edit submode
bmidx := -1;
bmink := 0;

# mesh block mode (echo of SpriteMeshEd, kept from the earlier port)
meshmode := 0;
vx, vy, vz: array of int;
fa, fb, fc, fcol: array of int;
nv, nf: int;
selected := -1;
pick0 := -1; pick1 := -1; pick2 := -1;
plane := 0;
meshgrid := 0;
meshink := int 16rFFFFFFFF;
lastx, lasty: int;

mainmenu := array[] of {
	"Color (4-bit)", "Dither Color (4-bit)", "Thick", "Planar Symmetry",
	"Point", "Line", "Arrow", "Rect", "Circle", "Ellipse", "Polygon",
	"Text", "Text Box", "Text Diamond", "Flood Fill",
	"Flood Fill Not Color", "PolyLine", "PolyPoint",
	"BSpline2", "BSpline3", "BSpline2 Closed", "BSpline3 Closed",
	"Insert Scrn-Captured BitMap", "Insert Transparent Scrn-Captured BitMap",
	"+] Create or Edit 3D Mesh", "+] Convert to BitMap or Edit BitMap",
	"Transform On(for use with 3D icons)", "Transform Off(for use with 3D icons)",
	"+] Sprite Edit Menu", "ExitSprite", "Abort Sprite",
};

editmenu := array[] of {
	"Select/Unselect All",
	"Select Elems", "Select Elems with Rects",
	"Unsel Elems", "Unsel Elems with Rects",
	"Shift Points", "Shift Points with Rects",
	"Shift Selected Elems", "Transform Selected Elems",
	"Set Origin", "Insert Shift SubOrigin",
	"Edit as Text", "Insert Sprite File", "Delete Selected Elems",
	"+] Sprite Main Menu", "ExitSprite", "Abort Sprite",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	pal = grpal->values();
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	blank = array[Cw*Ch*4] of byte;
	for(bi := 0; bi < len blank; bi++)
		blank[bi] = byte 255;
	work = array[len blank] of byte;
	if(argv != nil)
		argv = tl argv;
	if(argv != nil && hd argv == "-t"){
		# headless round-trip (load in, save out): format self-test
		argv = tl argv;
		out := "";
		if(argv != nil){
			path = hd argv;
			argv = tl argv;
		}
		if(argv != nil){
			out = hd argv;
			argv = tl argv;
		}
		if(argv != nil)
			name = hd argv;
		elems = array[64] of ref Elem;
		loadfile();
		sys->print("load: %s (%d elems, bare=%d, mesh=%d)\n", status, ne, bare, meshmode);
		if(!meshmode){
			# exercise the replay renderer (text needs a font; skipped)
			work[0:] = blank;
			replay(work);
			n := 0;
			for(i := 0; i < len work; i += 4)
				if(work[i] != byte 255 || work[i+1] != byte 255 || work[i+2] != byte 255)
					n++;
			sys->print("replay: %d inked pixels\n", n);
		}
		if(out != ""){
			path = out;
			savefile();
			sys->print("save: %s\n", status);
		}
		return;
	}
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	if(argv != nil){
		path = hd argv;
		argv = tl argv;
	}
	if(argv != nil)
		name = hd argv;

	win = wmclient->window(ctxt, "TempleOS Sprite Editor", Wmclient->Appl);
	display = win.display;
	font = Font.open(display, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(display, "/fonts/lucida/unicode.8.font");
	if(font != nil)
		fonth = font.height+2;
	palimg = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		palimg[i] = display.color(pal[i]);
	cachev = array[64] of int;
	cachei = array[64] of ref Image;

	canvasimg = display.newimage(Rect((0,0),(Cw,Ch)), Draw->RGBA32, 0, Draw->White);

	elems = array[64] of ref Elem;
	loadfile();
	snapshot();

	win.reshape(Rect((0, 0), (W, H)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	settool("Sprite Main Menu");
	redraw();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		pointer(p);
	k := <-win.ctxt.kbd =>
		kbd(k);
	}
}

settool(s: string)
{
	# SMTaskTitleSet: the title bar tracks the current tool
	win.settitle("SpriteEd: "+s);
}

# ---------- element bookkeeping ----------

mkelem(kind, na: int): ref Elem
{
	return ref Elem(kind, array[na] of {* => 0}, 0.0, nil, nil, nil, 0, 0, 0, nil);
}

copyelem(e: ref Elem): ref Elem
{
	c := ref Elem(e.kind, nil, e.ang, nil, nil, e.txt, e.sel, 0, 0, nil);
	if(e.a != nil){ c.a = array[len e.a] of int; c.a[0:] = e.a; }
	if(e.pts != nil){ c.pts = array[len e.pts] of int; c.pts[0:] = e.pts; }
	if(e.data != nil){ c.data = array[len e.data] of byte; c.data[0:] = e.data; }
	return c;
}

ins(e: ref Elem)
{
	if(ne == len elems){
		na := array[2*len elems] of ref Elem;
		na[0:] = elems[0:ne];
		elems = na;
	}
	for(i := ne; i > cur; i--)
		elems[i] = elems[i-1];
	elems[cur] = e;
	ne++;
	cur++;
	status = "inserted "+names[e.kind];
}

del(i: int)
{
	if(i < 0 || i >= ne)
		return;
	for(j := i; j < ne-1; j++)
		elems[j] = elems[j+1];
	ne--;
	if(cur > i)
		cur--;
}

delsel()
{
	n := 0;
	for(i := 0; i < ne;){
		if(elems[i].sel){
			del(i);
			n++;
		}else
			i++;
	}
	status = sys->sprint("deleted %d elems", n);
}

selcnt(): int
{
	n := 0;
	for(i := 0; i < ne; i++)
		if(elems[i].sel)
			n++;
	return n;
}

selall(v: int)
{
	for(i := 0; i < ne; i++)
		elems[i].sel = v;
}

snapshot()
{
	snap = array[ne] of ref Elem;
	for(i := 0; i < ne; i++)
		snap[i] = copyelem(elems[i]);
	nsnap = ne;
}

# SpriteSetSettings: DC state accumulated by the elements before n
stateat(n: int): (int, int, int, int, int, int)
{
	c := 0; d0 := -1; d1 := 0; t := 1; sx := 0; sy := 0;
	for(i := 0; i < n && i < ne; i++){
		e := elems[i];
		case e.kind {
		SCOLOR => c = e.a[0]; d0 = -1;
		SDITHER => d0 = e.a[0]; d1 = e.a[1];
		STHICK => t = e.a[0];
		SSHIFT => sx += e.a[0]; sy += e.a[1];
		}
	}
	return (c, d0, d1, t, sx, sy);
}

# element coords of a canvas point, given the insertion point's shift
ecoord(cx, cy: int): (int, int)
{
	(nil, nil, nil, nil, sx, sy) := stateat(cur);
	return (cx - Cw/2 - sx, cy - Ch/2 - sy);
}

# ---------- software raster (TempleOS DC semantics) ----------

setpix(x, y, c: int)
{
	if(x < 0 || x >= Cw || y < 0 || y >= Ch)
		return;
	i := (y*Cw+x)*4;
	if(c == TRANSP){
		rbuf[i] = byte 255; rbuf[i+1] = byte 255;
		rbuf[i+2] = byte 255; rbuf[i+3] = byte 255;
		return;
	}
	v := pal[c&15];
	rbuf[i] = byte (v>>24);
	rbuf[i+1] = byte (v>>16);
	rbuf[i+2] = byte (v>>8);
	rbuf[i+3] = byte 255;
}

getpix(x, y: int): int
{
	if(x < 0 || x >= Cw || y < 0 || y >= Ch)
		return -1;
	i := (y*Cw+x)*4;
	return (int rbuf[i]<<24) | (int rbuf[i+1]<<16) | (int rbuf[i+2]<<8) | int rbuf[i+3];
}

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

putf(x, y: real)
{
	xi := int x;
	yi := int y;
	setpix(xi, yi, pickc(xi, yi));
	if(symon){
		(rx, ry) := reflectpt(x, y);
		ri := int rx;
		rj := int ry;
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
	if(x < 0 || x >= Cw || y < 0 || y >= Ch)
		return;
	target := getpix(x, y);
	inkv := pal[rcol&15];
	if(rcol == TRANSP)
		inkv = int 16rFFFFFFFF;
	if(!notcolor && target == inkv && rd0 < 0)
		return;
	if(fseen == nil){
		fseen = array[Cw*Ch] of byte;
		fzero = array[Cw*Ch] of byte;
		fstack = array[Cw*Ch] of int;
	}
	fseen[0:] = fzero;
	seen := fseen;
	stack := fstack;
	sp := 0;
	# Mark a pixel seen when it is PUSHED, not when it is popped.  Both
	# fill the same region - nothing writes a pixel but its own pop -
	# but marking at pop lets one pixel be pushed once per neighbour,
	# so the stack needs four times the canvas and it is exactly the
	# canvas.  A fill large enough to reach the canvas edge overruns it.
	seen[y*Cw+x] = byte 1;
	stack[sp++] = y*Cw+x;
	while(sp > 0){
		pos := stack[--sp];
		px := pos%Cw;
		py := pos/Cw;
		v := getpix(px, py);
		if(notcolor){
			if(v == inkv)
				continue;
		}else if(v != target)
			continue;
		setpix(px, py, pickc(px, py));
		if(px+1 < Cw && seen[pos+1] == byte 0){
			seen[pos+1] = byte 1;
			stack[sp++] = pos+1;
		}
		if(px > 0 && seen[pos-1] == byte 0){
			seen[pos-1] = byte 1;
			stack[sp++] = pos-1;
		}
		if(py+1 < Ch && seen[pos+Cw] == byte 0){
			seen[pos+Cw] = byte 1;
			stack[sp++] = pos+Cw;
		}
		if(py > 0 && seen[pos-Cw] == byte 0){
			seen[pos-Cw] = byte 1;
			stack[sp++] = pos-Cw;
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
	x := Cw/2 + rsx;
	y := Ch/2 + rsy;
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

replay(buf: array of byte)
{
	rbuf = buf;
	rcol = 0; rd0 = -1; rd1 = 0; rthk = 1;
	rsx = 0; rsy = 0;
	symon = 0;
	for(i := 0; i <= ne; i++){
		if(pvon && i == cur)
			drawelem(pv);
		if(i < ne)
			drawelem(elems[i]);
	}
}

nearestpal(v: int): int
{
	r := (v>>24)&255;
	g := (v>>16)&255;
	b := (v>>8)&255;
	best := 0;
	bd := 1<<30;
	for(i := 0; i < 16; i++){
		pr := (pal[i]>>24)&255;
		pg := (pal[i]>>16)&255;
		pb := (pal[i]>>8)&255;
		d := (r-pr)*(r-pr) + (g-pg)*(g-pg) + (b-pb)*(b-pb);
		if(d < bd){
			bd = d;
			best = i;
		}
	}
	return best;
}

# capture the replayed canvas in [x1,x2)x[y1,y2) as a bitmap element
capture(x1, y1, x2, y2, transp: int): ref Elem
{
	if(x2 < x1){ t := x1; x1 = x2; x2 = t; }
	if(y2 < y1){ t := y1; y1 = y2; y2 = t; }
	x2++;
	y2++;
	w := x2-x1;
	h := y2-y1;
	if(w < 1 || h < 1)
		return nil;
	stride := (w+7)&~7;
	e := mkelem(SBITMAP, 4);
	(ex, ey) := ecoord(x1, y1);
	e.a[0] = ex;
	e.a[1] = ey;
	e.a[2] = w;
	e.a[3] = h;
	e.data = array[stride*h] of {* => byte TRANSP};
	rbuf = work;
	for(yy := 0; yy < h; yy++)
		for(xx := 0; xx < w; xx++){
			v := getpix(x1+xx, y1+yy);
			if(v < 0)
				continue;
			c := nearestpal(v);
			if(transp >= 0 && c == transp)
				continue;
			e.data[yy*stride+xx] = byte c;
		}
	return e;
}

# ---------- polypt encode ----------

# code for a unit step (dx,dy) in {-1,0,1}, -1 = no move
enccode := array[] of {5, 6, 7, 4, -1, 0, 3, 2, 1};

walkappend(e: ref Elem, x2, y2: int, lx, ly: int): (int, int)
{
	# extend polypt e (absolute last position lx,ly) toward x2,y2
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

polyptabs(e: ref Elem): array of int
{
	# absolute point list of a polypt element (including start)
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

# ---------- transforms (Sprite Edit Menu / SpriteTransformQue) ----------

applyxform(deg, scale: real)
{
	auto := 0;
	if(selcnt() == 0){
		selall(1);
		auto = 1;
	}
	th := deg*Math->Pi/180.0;
	c := scale*math->cos(th);
	s := scale*math->sin(th);
	for(i := 0; i < ne; i++){
		e := elems[i];
		if(!e.sel)
			continue;
		elems[i] = xelem(e, c, s, th, scale);
	}
	if(auto)
		selall(0);
	status = "transformed";
}

xpt(x, y: int, c, s: real): (int, int)
{
	return (int (real x*c - real y*s), int (real x*s + real y*c));
}

xelem(e: ref Elem, c, s, th, k: real): ref Elem
{
	case e.kind {
	STHICK =>
		e.a[0] = int (real e.a[0]*k);
		if(e.a[0] < 1)
			e.a[0] = 1;
	SLINE or SARROW or SPLANARSYM =>
		(e.a[0], e.a[1]) = xpt(e.a[0], e.a[1], c, s);
		(e.a[2], e.a[3]) = xpt(e.a[2], e.a[3], c, s);
	SRECT or SROTRECT =>
		# TempleOS promotes rect to rotated rect under transform
		w := int (real(e.a[2]-e.a[0])*k);
		h := int (real(e.a[3]-e.a[1])*k);
		(nx, ny) := xpt(e.a[0], e.a[1], c, s);
		r := mkelem(SROTRECT, 4);
		r.a[0] = nx;
		r.a[1] = ny;
		r.a[2] = nx+w;
		r.a[3] = ny+h;
		r.ang = e.ang + th;
		r.sel = e.sel;
		return r;
	SCIRCLE =>
		(e.a[0], e.a[1]) = xpt(e.a[0], e.a[1], c, s);
		e.a[2] = int (real e.a[2]*k);
	SELLIPSE or SPOLYGON =>
		(e.a[0], e.a[1]) = xpt(e.a[0], e.a[1], c, s);
		e.a[2] = int (real e.a[2]*k);
		e.a[3] = int (real e.a[3]*k);
		e.ang = e.ang + th;
	SPT or SFLOOD or SFLOODNOT or STEXT or STEXTBOX or STEXTDIAMOND or SBITMAP =>
		(e.a[0], e.a[1]) = xpt(e.a[0], e.a[1], c, s);
	SPOLYLINE =>
		for(i := 0; i < len e.pts; i += 2)
			(e.pts[i], e.pts[i+1]) = xpt(e.pts[i], e.pts[i+1], c, s);
	SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
		for(i := 0; i < len e.pts; i += 3)
			(e.pts[i], e.pts[i+1]) = xpt(e.pts[i], e.pts[i+1], c, s);
	SPOLYPT =>
		# re-walk the transformed step path, as SpriteTransformQue does
		p := polyptabs(e);
		r := mkelem(SPOLYPT, 3);
		r.sel = e.sel;
		(r.a[1], r.a[2]) = xpt(p[0], p[1], c, s);
		lx := r.a[1];
		ly := r.a[2];
		for(i := 2; i < len p; i += 2){
			(nx, ny) := xpt(p[i], p[i+1], c, s);
			(lx, ly) = walkappend(r, nx, ny, lx, ly);
		}
		return r;
	}
	return e;
}

# SpriteSetOrigin: add a delta to every (non-shift) element's coordinates
addall(dx, dy: int)
{
	for(i := 0; i < ne; i++){
		e := elems[i];
		case e.kind {
		SLINE or SARROW or SPLANARSYM or SRECT or SROTRECT =>
			e.a[0] += dx; e.a[1] += dy;
			e.a[2] += dx; e.a[3] += dy;
		SPT or SFLOOD or SFLOODNOT or STEXT or STEXTBOX or
		STEXTDIAMOND or SCIRCLE or SBITMAP or SELLIPSE or SPOLYGON =>
			e.a[0] += dx; e.a[1] += dy;
		SPOLYLINE =>
			for(j := 0; j < len e.pts; j += 2){
				e.pts[j] += dx;
				e.pts[j+1] += dy;
			}
		SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
			for(j := 0; j < len e.pts; j += 3){
				e.pts[j] += dx;
				e.pts[j+1] += dy;
			}
		SPOLYPT =>
			e.a[1] += dx; e.a[2] += dy;
		}
	}
}

# ---------- control points (SpritePtQueNew / SpriteCtrlPtsDraw) ----------

buildcps()
{
	cpe = array[4*ne+16] of int;
	cpw = array[len cpe] of int;
	cpsel = array[len cpe] of int;
	ncp = 0;
	for(i := 0; i < ne; i++){
		e := elems[i];
		case e.kind {
		SELLIPSE or SPOLYGON =>
			addcp(i, 2);	# width/height handle
			addcp(i, 0);
		SRECT or SROTRECT or SLINE or SARROW or SPLANARSYM =>
			addcp(i, 1);
			addcp(i, 0);
		STEXT or STEXTBOX or STEXTDIAMOND or SPT or SBITMAP or
		SFLOOD or SFLOODNOT or SCIRCLE =>
			addcp(i, 0);
		SPOLYPT =>
			addcp(i, 3);
		SPOLYLINE =>
			for(j := 0; j < len e.pts/2; j++)
				addcp(i, 100+j);
		SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
			for(j := 0; j < len e.pts/3; j++)
				addcp(i, 100+j);
		}
	}
}

addcp(ei, w: int)
{
	if(ncp == len cpe){
		na := array[2*len cpe] of int;
		na[0:] = cpe; cpe = na;
		na = array[len cpe] of int;
		na[0:] = cpw[0:ncp]; cpw = na;
		na = array[len cpe] of int;
		na[0:] = cpsel[0:ncp]; cpsel = na;
	}
	cpe[ncp] = ei;
	cpw[ncp] = w;
	cpsel[ncp] = 0;
	ncp++;
}

shiftbefore(ei: int): (int, int)
{
	sx := 0;
	sy := 0;
	for(i := 0; i < ei && i < ne; i++)
		if(elems[i].kind == SSHIFT){
			sx += elems[i].a[0];
			sy += elems[i].a[1];
		}
	return (sx, sy);
}

cppos(i: int): (int, int)
{
	e := elems[cpe[i]];
	(sx, sy) := shiftbefore(cpe[i]);
	x := Cw/2+sx;
	y := Ch/2+sy;
	w := cpw[i];
	if(w >= 100){
		j := w-100;
		if(e.kind == SPOLYLINE)
			return (x+e.pts[2*j], y+e.pts[2*j+1]);
		return (x+e.pts[3*j], y+e.pts[3*j+1]);
	}
	case w {
	0 =>
		return (x+e.a[0], y+e.a[1]);
	1 =>
		return (x+e.a[2], y+e.a[3]);
	2 =>
		return (x+e.a[0]+e.a[2], y+e.a[1]+e.a[3]);
	3 =>
		return (x+e.a[1], y+e.a[2]);
	}
	return (x, y);
}

cpmovept(i, dx, dy: int)
{
	e := elems[cpe[i]];
	w := cpw[i];
	if(w >= 100){
		j := w-100;
		if(e.kind == SPOLYLINE){
			e.pts[2*j] += dx;
			e.pts[2*j+1] += dy;
		}else{
			e.pts[3*j] += dx;
			e.pts[3*j+1] += dy;
		}
		return;
	}
	case w {
	0 =>
		e.a[0] += dx; e.a[1] += dy;
	1 =>
		e.a[2] += dx; e.a[3] += dy;
	2 =>
		e.a[2] += dx; e.a[3] += dy;	# width/height handle
	3 =>
		e.a[1] += dx; e.a[2] += dy;
	}
}

cpmovesel(dx, dy: int)
{
	for(i := 0; i < ncp; i++)
		if(cpsel[i])
			cpmovept(i, dx, dy);
}

cpnearest(cx, cy: int): int
{
	best := -1;
	bd := 1<<30;
	for(i := 0; i < ncp; i++){
		(x, y) := cppos(i);
		d := (x-cx)*(x-cx) + (y-cy)*(y-cy);
		if(d < bd){
			bd = d;
			best = i;
		}
	}
	return best;
}

# ---------- file format ----------

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

readall(fd: ref Sys->FD): string
{
	s := "";
	b := array[8192] of byte;
	for(;;){
		r := sys->read(fd, b, len b);
		if(r <= 0)
			break;
		s += string b[0:r];
	}
	return s;
}

findstr(s, p: string, start: int): int
{
	if(len p == 0)
		return start;
	for(i := start; i+len p <= len s; i++)
		if(s[i:i+len p] == p)
			return i;
	return -1;
}

loadfile()
{
	elems = array[64] of ref Elem;
	ne = 0;
	cur = 0;
	meshmode = 0;
	bare = 0;
	prefix = suffix = nil;
	origtext = "";
	hadfile = 0;
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		if(len path > 4 && path[len path-4:] == ".spr")
			bare = 1;
		status = "new file";
		return;
	}
	hadfile = 1;
	s := readall(fd);
	origtext = s;
	key := ".SPRITE "+name;
	a := -1;
	for(p := 0;;){
		a = findstr(s, key, p);
		if(a < 0)
			break;
		# demand a real block start: line start, name is whole token
		e := a+len key;
		if((a == 0 || s[a-1] == '\n') &&
		   (e >= len s || s[e] == '\n' || s[e] == ' ' || s[e] == '\t' || s[e] == '\r'))
			break;
		p = a+1;
	}
	if(a < 0){
		mkey := ".MESH "+name+" ";
		m := findstr(s, mkey, 0);
		if(m >= 0){
			parse_mesh(s, m);
			return;
		}
		# whole file as a bare element list?
		(el, n, err) := parselist(s);
		if(err == "" && n > 0){
			elems = el;
			ne = n;
			cur = ne;
			bare = 1;
			status = sys->sprint("loaded %d elems", ne);
			return;
		}
		prefix = s;
		if(len prefix > 0 && prefix[len prefix-1] != '\n')
			prefix += "\n";
		suffix = nil;
		status = "block not found; will append";
		return;
	}
	eol := findstr(s, "\n", a);
	end := findstr(s, ".ENDSPRITE", eol+1);
	if(eol < 0 || end < 0){
		status = "bad sprite block";
		return;
	}
	endline := findstr(s, "\n", end);
	if(endline < 0)
		endline = len s;
	else
		endline++;
	prefix = s[0:a];
	suffix = s[endline:];
	(nh, hdr) := sys->tokenize(s[a:eol], " \t\r");
	body := s[eol+1:end];
	if(nh > 2){
		legacyraster(hdr, body);
		return;
	}
	(el, n, err) := parselist(body);
	if(err != ""){
		status = "load: "+err;
		return;
	}
	elems = el;
	ne = n;
	cur = ne;
	status = sys->sprint("loaded %d elems", ne);
}

# old ".SPRITE name w h r8g8b8a8" raster blocks become one bitmap element
legacyraster(hdr: list of string, body: string)
{
	hdr = tl tl hdr;	# skip .SPRITE name
	w := int hd hdr;
	h := int hd tl hdr;
	if(w < 1 || h < 1 || w > 1024 || h > 1024){
		status = "bad legacy raster size";
		return;
	}
	stride := (w+7)&~7;
	e := mkelem(SBITMAP, 4);
	e.a[0] = -w/2;
	e.a[1] = -h/2;
	e.a[2] = w;
	e.a[3] = h;
	e.data = array[stride*h] of {* => byte TRANSP};
	(nil, rows) := sys->tokenize(body, "\n");
	y := 0;
	for(; rows != nil && y < h; rows = tl rows){
		(nil, cells) := sys->tokenize(hd rows, " \t\r");
		x := 0;
		for(; cells != nil && x < w; cells = tl cells){
			v := hd cells;
			if(v != "."){
				iv := int v;
				if((iv&255) != 0)
					e.data[y*stride+x] = byte nearestpal(iv);
			}
			x++;
		}
		y++;
	}
	elems[0] = e;
	ne = 1;
	cur = 1;
	status = "legacy raster converted to bitmap elem";
}

savefile()
{
	if(meshmode){
		save_mesh();
		return;
	}
	body := "";
	for(i := 0; i < ne; i++)
		body += elemline(elems[i])+"\n";
	s: string;
	if(bare)
		s = body;
	else
		s = prefix+".SPRITE "+name+"\n"+body+".ENDSPRITE\n"+suffix;
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil){
		status = sys->sprint("save: %r");
		return;
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b){
		status = sys->sprint("save: %r");
		return;
	}
	wrote = 1;
	status = "saved "+path;
}

insertfile(p2: string)
{
	fd := sys->open(p2, Sys->OREAD);
	if(fd == nil){
		status = sys->sprint("open %s: %r", p2);
		return;
	}
	(el, n, err) := parselist(readall(fd));
	if(err != ""){
		status = "parse "+p2+": "+err;
		return;
	}
	for(i := 0; i < n; i++)
		ins(el[i]);
	status = sys->sprint("inserted %d elems from %s", n, p2);
}

exitsave()
{
	savefile();
	win.wmctl("exit");
}

abort()
{
	# SPE_ABORT: restore the pre-edit data
	if(wrote && hadfile){
		fd := sys->create(path, Sys->OWRITE, 8r664);
		if(fd != nil){
			b := array of byte origtext;
			sys->write(fd, b, len b);
		}
	}
	win.wmctl("exit");
}

# ---------- summaries (SpriteElem2Summary) ----------

colname := array[] of {
	"BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
	"DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE", "YELLOW", "WHITE",
};

cname(c: int): string
{
	if(c == TRANSP)
		return "TRANSPARENT";
	if(c >= 0 && c < 16)
		return colname[c];
	return sys->sprint("%d", c);
}

sumline(e: ref Elem): string
{
	case e.kind {
	SCOLOR =>
		return "Color "+cname(e.a[0]);
	SDITHER =>
		return "Dither "+cname(e.a[0])+"/"+cname(e.a[1]);
	STHICK =>
		return sys->sprint("Thick %d", e.a[0]);
	SPLANARSYM =>
		if(e.a[0] == e.a[2] && e.a[1] == e.a[3])
			return "Symmetry off";
		return sys->sprint("Symmetry (%d,%d)-(%d,%d)", e.a[0], e.a[1], e.a[2], e.a[3]);
	STRANSON =>
		return "Transform ON";
	STRANSOFF =>
		return "Transform OFF";
	SSHIFT =>
		return sys->sprint("Shift (%d,%d)", e.a[0], e.a[1]);
	SPT =>
		return sys->sprint("Pt (%d,%d)", e.a[0], e.a[1]);
	SLINE =>
		return sys->sprint("Line (%d,%d)-(%d,%d)", e.a[0], e.a[1], e.a[2], e.a[3]);
	SARROW =>
		return sys->sprint("Arrow (%d,%d)-(%d,%d)", e.a[0], e.a[1], e.a[2], e.a[3]);
	SRECT =>
		return sys->sprint("Rect (%d,%d)-(%d,%d)", e.a[0], e.a[1], e.a[2], e.a[3]);
	SROTRECT =>
		return sys->sprint("RotRect (%d,%d) %.2f", e.a[0], e.a[1], e.ang);
	SCIRCLE =>
		return sys->sprint("Circle (%d,%d) r%d", e.a[0], e.a[1], e.a[2]);
	SELLIPSE =>
		return sys->sprint("Ellipse (%d,%d) %dx%d", e.a[0], e.a[1], e.a[2], e.a[3]);
	SPOLYGON =>
		return sys->sprint("Polygon%d (%d,%d)", e.a[4], e.a[0], e.a[1]);
	SPOLYLINE =>
		return sys->sprint("PolyLine n=%d", len e.pts/2);
	SPOLYPT =>
		return sys->sprint("PolyPt n=%d (%d,%d)", e.a[0], e.a[1], e.a[2]);
	SBSPLINE2 =>
		return sys->sprint("BSpline2 n=%d", len e.pts/3);
	SBSPLINE2C =>
		return sys->sprint("BSpline2C n=%d", len e.pts/3);
	SBSPLINE3 =>
		return sys->sprint("BSpline3 n=%d", len e.pts/3);
	SBSPLINE3C =>
		return sys->sprint("BSpline3C n=%d", len e.pts/3);
	SFLOOD =>
		return sys->sprint("FloodFill (%d,%d)", e.a[0], e.a[1]);
	SFLOODNOT =>
		return sys->sprint("FloodFillNot (%d,%d)", e.a[0], e.a[1]);
	SBITMAP =>
		return sys->sprint("BitMap %dx%d (%d,%d)", e.a[2], e.a[3], e.a[0], e.a[1]);
	SMESH =>
		return "Mesh (see .MESH)";
	SSHIFTMESH =>
		return "ShiftMesh (see .MESH)";
	STEXT or STEXTBOX or STEXTDIAMOND =>
		t := e.txt;
		if(len t > 10)
			t = t[0:10];
		return names[e.kind]+" '"+t+"'";
	}
	return names[e.kind];
}

# ---------- rendering ----------

colour(v: int): ref Image
{
	for(i := 0; i < ncache; i++)
		if(cachev[i] == v)
			return cachei[i];
	c := display.color(v);
	if(ncache < len cachev){
		cachev[ncache] = v;
		cachei[ncache++] = c;
	}
	return c;
}

txt(img: ref Image, x, y, c: int, s: string)
{
	if(font != nil)
		img.text(Point(x, y), palimg[c], Point(0, 0), font, s);
}

boxo(img: ref Image, r: Rect, c: int)
{
	img.line(r.min, Point(r.max.x-1, r.min.y), 0, 0, 0, palimg[c], Point(0,0));
	img.line(Point(r.max.x-1, r.min.y), Point(r.max.x-1, r.max.y-1), 0, 0, 0, palimg[c], Point(0,0));
	img.line(Point(r.max.x-1, r.max.y-1), Point(r.min.x, r.max.y-1), 0, 0, 0, palimg[c], Point(0,0));
	img.line(Point(r.min.x, r.max.y-1), r.min, 0, 0, 0, palimg[c], Point(0,0));
}

toolname(): string
{
	case mode {
	Mmain =>
		return "Sprite Main Menu";
	Medit =>
		return "Sprite Edit Menu";
	Mtext =>
		return "Enter text";
	Mnum or Mfile or Mxform =>
		return "prompt";
	Mpoints =>
		case pmode {
		PMsel =>	return "Select Elems";
		PMselrect =>	return "Select Elems with Rects";
		PMunsel =>	return "Unsel Elems";
		PMunselrect =>	return "Unsel Elems with Rects";
		PMshift =>	return "Shift Points";
		PMshiftrect =>	return "Shift Points with Rects";
		}
	Mshiftsel =>
		return "Shift Selected";
	Msetorigin =>
		return "Set Origin";
	Msuborigin =>
		return "Insert Shift SubOrigin";
	Mbitmap =>
		return "BitMap Edit";
	Mtool =>
		case tool {
		TCAPTURE =>	return "Insert Scrn BitMap";
		TCAPTURET =>	return "Insert Transparent Scrn BitMap";
		TBITMAPED =>	return "BitMap Extents";
		* =>		return names[tool];
		}
	}
	return "";
}

hintline(): string
{
	case mode {
	Mmain or Medit =>
		return "click a menu entry; palette inserts a Color elem; d=del sel  s=save  q=exit";
	Mtext =>
		return "type the text, then Enter or Esc; empty cancels";
	Mnum =>
		return "type a number, then Enter; Esc cancels";
	Mfile =>
		return "type a file path (e.g. lib/temple/sprites/bigguns_1.spr), Enter";
	Mxform =>
		return "degrees to rotate, or s<factor> to scale (e.g. 30 or s1.5), Enter";
	Mpoints =>
		return "LMB pick/drag  p=points r=rects  RMB=edit menu";
	Mshiftsel =>
		return "drag to move selected elems; RMB done";
	Msetorigin =>
		return "click the new origin";
	Msuborigin =>
		return "drag to set the sub-origin shift; RMB done";
	Mbitmap =>
		return "LMB paint  RMB erase  palette=ink  Esc done";
	Mtool =>
		case tool {
		SPOLYLINE or SBSPLINE2 or SBSPLINE3 or SBSPLINE2C or SBSPLINE3C =>
			return "click points; RMB finishes the element";
		SPOLYPT =>
			return "hold LMB and draw freehand";
		SELLIPSE or SPOLYGON =>
			return "drag radii, release, turn, click to set rotation";
		TCAPTURE or TCAPTURET or TBITMAPED =>
			return "drag out a rect for the extents of the bitmap";
		* =>
			return "LMB draws  c=eye-dropper t=transparent  RMB=menu  Esc=exit";
		}
	}
	return "";
}

redraw()
{
	if(meshmode){
		redraw_mesh();
		return;
	}
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, palimg[LTGRAY], nil, Point(0, 0));
	# top bar
	txt(img, o.x+4, o.y+2, BLACK,
		sys->sprint("%s [%s] %s -- %s", path, name, toolname(), status));
	txt(img, o.x+4, o.y+2+fonth, DKGRAY, hintline());
	# canvas rect
	canr = Rect((o.x+Sw+2, o.y+Topb), (o.x+Sw+2+Cw, o.y+Topb+Ch));
	if(canr.max.x > img.r.max.x)
		canr.max.x = img.r.max.x;
	if(canr.max.y > img.r.max.y)
		canr.max.y = img.r.max.y;
	drawpalette(img, o);
	drawlist(img, o);
	if(mode == Mmain || mode == Medit)
		drawmenu(img);
	else if(mode == Mbitmap)
		drawbitmaped(img);
	else{
		work[0:] = blank;
		replay(work);
		canvasimg.writepixels(canvasimg.r, work);
		img.draw(canr, canvasimg, nil, Point(0, 0));
		# origin crosshair (overlay only; not part of the raster)
		oc := Point(canr.min.x+Cw/2, canr.min.y+Ch/2);
		if(canr.contains(oc)){
			img.line(Point(oc.x-4, oc.y), Point(oc.x+4, oc.y), 0, 0, 0, palimg[LTGRAY], Point(0,0));
			img.line(Point(oc.x, oc.y-4), Point(oc.x, oc.y+4), 0, 0, 0, palimg[LTGRAY], Point(0,0));
		}
		# SpriteScrnInit: mark the active symmetry plane with a red line
		if(symon){
			dx := sbx-sax;
			dy := sby-say;
			m := math->sqrt(dx*dx+dy*dy);
			if(m > 0.0){
				dx = dx/m*1000.0;
				dy = dy/m*1000.0;
				p0 := Point(canr.min.x+int(sax-dx), canr.min.y+int(say-dy));
				p1 := Point(canr.min.x+int(sbx+dx), canr.min.y+int(sby+dy));
				img.line(p0, p1, 0, 0, 0, palimg[LTRED], Point(0,0));
			}
		}
		if(capon){
			r := Rect((canr.min.x+capx0, canr.min.y+capy0),
				(canr.min.x+capx1+1, canr.min.y+capy1+1));
			boxo(img, r.canon(), LTRED);
		}
		if(mode == Mpoints)
			drawhandles(img);
	}
	if(mode == Mtext || mode == Mnum || mode == Mfile || mode == Mxform){
		pr := Rect((canr.min.x, canr.max.y-fonth-4), (canr.max.x, canr.max.y));
		img.draw(pr, palimg[WHITE], nil, Point(0,0));
		txt(img, pr.min.x+4, pr.min.y+2, BLACK, promptlabel()+pbuf+"_");
	}
	img.flush(Draw->Flushnow);
}

promptlabel(): string
{
	case mode {
	Mtext =>
		return "text: ";
	Mnum =>
		if(numfor == Nsides)
			return "num of sides (3-16): ";
		return "thick (1-16): ";
	Mfile =>
		return "sprite file: ";
	Mxform =>
		return "transform: ";
	}
	return "";
}

drawpalette(img: ref Image, o: Point)
{
	palr = Rect((o.x+2, o.y+Topb), (o.x+2+8*26, o.y+Topb+2*26));
	for(i := 0; i < 16; i++){
		x := palr.min.x + (i%8)*26;
		y := palr.min.y + (i/8)*26;
		r := Rect((x, y), (x+24, y+24));
		img.draw(r, palimg[i], nil, Point(0,0));
		boxo(img, r, BLACK);
	}
	# transparent cell
	tr := Rect((palr.min.x, palr.max.y+2), (palr.min.x+24, palr.max.y+26));
	img.draw(tr, palimg[WHITE], nil, Point(0,0));
	boxo(img, tr, DKGRAY);
	txt(img, tr.min.x+8, tr.min.y+8, DKGRAY, "T");
	# state at the insertion point
	(c, d0, d1, t, nil, nil) := stateat(cur);
	sr := Rect((tr.max.x+8, tr.min.y+4), (tr.max.x+24, tr.min.y+20));
	if(d0 >= 0){
		img.draw(Rect(sr.min, Point(sr.max.x, (sr.min.y+sr.max.y)/2)), palimg[d0&15], nil, Point(0,0));
		img.draw(Rect(Point(sr.min.x, (sr.min.y+sr.max.y)/2), sr.max), palimg[d1&15], nil, Point(0,0));
	}else if(c == TRANSP)
		txt(img, sr.min.x, sr.min.y+4, DKGRAY, "T");
	else
		img.draw(sr, palimg[c&15], nil, Point(0,0));
	boxo(img, sr, BLACK);
	txt(img, sr.max.x+6, sr.min.y+4, BLACK, sys->sprint("thick %d", t));
}

drawlist(img: ref Image, o: Point)
{
	y0 := o.y+Topb+2*26+30;
	listr = Rect((o.x+2, y0), (o.x+Sw-2, img.r.max.y-4));
	txt(img, listr.min.x, y0-fonth-2, BLACK, sys->sprint("elems (%d):", ne));
	lh := fonth+2;
	rows := listr.dy()/lh;
	# keep the insertion point visible when it moves
	if(cur != lastcur){
		if(cur < listtop)
			listtop = cur;
		if(cur >= listtop+rows)
			listtop = cur-rows+1;
		lastcur = cur;
	}
	if(listtop < 0)
		listtop = 0;
	for(i := 0; i < rows; i++){
		idx := listtop+i;
		if(idx > ne)
			break;
		y := listr.min.y + i*lh;
		s: string;
		c := LTBLUE;
		if(idx == ne)
			s = "END";
		else{
			s = sumline(elems[idx]);
			if(elems[idx].sel){
				s = "*"+s;
				c = PURPLE;
			}
		}
		if(idx == cur){
			c = LTRED;
			img.draw(Rect((listr.min.x, y), (listr.max.x, y+lh)), palimg[WHITE], nil, Point(0,0));
		}
		if(len s > 26)
			s = s[0:26];
		txt(img, listr.min.x+2, y, c, s);
	}
}

drawmenu(img: ref Image)
{
	img.draw(canr, palimg[WHITE], nil, Point(0,0));
	items := mainmenu;
	title := "Sprite Main Menu";
	if(mode == Medit){
		items = editmenu;
		title = "Sprite Edit Menu";
	}
	x := canr.min.x+24;
	y := canr.min.y+8;
	txt(img, x+80, y, PURPLE, title);
	y += fonth+8;
	lh := menulh();
	for(i := 0; i < len items; i++){
		c := LTBLUE;
		if(items[i][0] == '+')
			c = PURPLE;
		txt(img, x, y+i*lh, c, items[i]);
	}
	txt(img, x, canr.max.y-fonth-4, BLACK, "Right-Click to get back to this menu.");
}

menulh(): int
{
	n := len mainmenu;
	if(mode == Medit)
		n = len editmenu;
	lh := (canr.dy()-fonth-24-fonth-8)/n;
	if(lh < fonth)
		lh = fonth;
	if(lh > fonth+6)
		lh = fonth+6;
	return lh;
}

menuhit(y: int): int
{
	top := canr.min.y+8+fonth+8;
	lh := menulh();
	i := (y-top)/lh;
	n := len mainmenu;
	if(mode == Medit)
		n = len editmenu;
	if(y < top || i < 0 || i >= n)
		return -1;
	return i;
}

drawhandles(img: ref Image)
{
	# SpriteCtrlPtsDraw: 4x4 black/white handles, red when selected
	for(i := 0; i < ncp; i++){
		(x, y) := cppos(i);
		p := Point(canr.min.x+x, canr.min.y+y);
		if(!canr.contains(p))
			continue;
		c := BLACK;
		if(cpsel[i])
			c = LTRED;
		img.draw(Rect((p.x-2, p.y-2), (p.x+2, p.y+2)), palimg[c], nil, Point(0,0));
		img.draw(Rect((p.x-1, p.y-1), (p.x+1, p.y+1)), palimg[WHITE], nil, Point(0,0));
	}
	if(dragging && (pmode == PMselrect || pmode == PMunselrect || pmode == PMshiftrect)){
		r := Rect((canr.min.x+capx0, canr.min.y+capy0),
			(canr.min.x+capx1+1, canr.min.y+capy1+1));
		boxo(img, r.canon(), LTRED);
	}
}

drawbitmaped(img: ref Image)
{
	img.draw(canr, palimg[WHITE], nil, Point(0,0));
	if(bmidx < 0 || bmidx >= ne)
		return;
	e := elems[bmidx];
	w := e.a[2];
	h := e.a[3];
	if(w < 1 || h < 1)
		return;
	cell := (canr.dx()-16)/w;
	if((canr.dy()-16)/h < cell)
		cell = (canr.dy()-16)/h;
	if(cell < 2)
		cell = 2;
	if(cell > 24)
		cell = 24;
	gx := canr.min.x + (canr.dx()-w*cell)/2;
	gy := canr.min.y + (canr.dy()-h*cell)/2;
	stride := (w+7)&~7;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			r := Rect((gx+x*cell, gy+y*cell), (gx+(x+1)*cell, gy+(y+1)*cell));
			c := int e.data[y*stride+x];
			if(c == TRANSP){
				ck := WHITE;
				if((x+y)&1)
					ck = LTGRAY;
				img.draw(r, palimg[ck], nil, Point(0,0));
			}else
				img.draw(r, palimg[c&15], nil, Point(0,0));
		}
	boxo(img, Rect((gx, gy), (gx+w*cell, gy+h*cell)), BLACK);
	txt(img, canr.min.x+4, canr.min.y+2, BLACK,
		sys->sprint("bitmap %dx%d  ink %s", w, h, cname(bmink)));
}

# ---------- input ----------

kbd(k: int)
{
	case mode {
	Mtext or Mnum or Mfile or Mxform =>
		if(k == 8){		# backspace
			if(len pbuf > 0)
				pbuf = pbuf[0:len pbuf-1];
		}else if(k == '\n' || k == '\r' || (k == 16r1b && mode == Mtext))
			promptdone();
		else if(k == 16r1b){
			pbuf = "";
			mode = Mmain;
			settool(toolname());
		}else if(k >= 32)
			pbuf[len pbuf] = k;
		redraw();
		return;
	}
	if(meshmode){
		meshkbd(k);
		return;
	}
	case k {
	16r1b =>
		# CH_ESC exits the sprite (keeping changes), as in SpriteMainEd;
		# submodes fall back a level first
		case mode {
		Mpoints =>
			mode = Medit;
		Mbitmap =>
			mode = Mmain;
		Mshiftsel or Msetorigin or Msuborigin =>
			mode = Medit;
		* =>
			exitsave();
		}
		pvon = 0;
		phase = 0;
		settool(toolname());
		redraw();
	'q' or 'Q' =>
		exitsave();
	'A' =>
		abort();
	's' or 'S' =>
		savefile();
		redraw();
	'l' or 'L' =>
		loadfile();
		snapshot();
		wrote = 0;
		mode = Mmain;
		pvon = 0;
		redraw();
	'd' or 'D' =>
		if(mode == Mmain || mode == Medit){
			delsel();
			redraw();
		}
	'c' =>
		# eye-dropper: color under the mouse becomes a Color elem
		if(mode == Mtool){
			work[0:] = blank;
			pvon2 := pvon;
			pvon = 0;
			replay(work);
			pvon = pvon2;
			rbuf = work;
			v := getpix(mcx, mcy);
			if(v >= 0){
				e := mkelem(SCOLOR, 1);
				e.a[0] = nearestpal(v);
				ins(e);
				redraw();
			}
		}
	't' =>
		if(mode == Mtool || mode == Mmain){
			e := mkelem(SCOLOR, 1);
			e.a[0] = TRANSP;
			ins(e);
			redraw();
		}
	'p' or 'P' =>
		if(mode == Mpoints){
			pmode &= ~1;
			settool(toolname());
			redraw();
		}
	'r' or 'R' =>
		if(mode == Mpoints){
			pmode |= 1;
			settool(toolname());
			redraw();
		}
	}
}

promptdone()
{
	case mode {
	Mtext =>
		if(pbuf == ""){
			mode = Mmain;
			break;
		}
		pv = mkelem(texttool, 2);
		pv.txt = pbuf;
		(pv.a[0], pv.a[1]) = ecoord(mcx, mcy);
		pvon = 1;
		mode = Mtool;
		tool = texttool;
		phase = 1;
	Mnum =>
		v := int pbuf;
		if(numfor == Nsides){
			if(v < 3 || v > 16){
				status = "sides must be 3-16";
				mode = Mmain;
			}else{
				sides = v;
				tool = SPOLYGON;
				mode = Mtool;
				phase = 0;
			}
		}else{
			if(v < 1 || v > 16)
				status = "thick must be 1-16";
			else{
				e := mkelem(STHICK, 1);
				e.a[0] = v;
				ins(e);
			}
			mode = Mmain;
		}
	Mfile =>
		if(pbuf != "")
			insertfile(pbuf);
		mode = Medit;
	Mxform =>
		if(pbuf != ""){
			if(pbuf[0] == 's' || pbuf[0] == 'S')
				applyxform(0.0, real pbuf[1:]);
			else
				applyxform(real pbuf, 1.0);
		}
		mode = Medit;
	}
	pbuf = "";
	settool(toolname());
	redraw();
}

pointer(p: ref Draw->Pointer)
{
	if(meshmode){
		mesh_pointer(p);
		return;
	}
	b := p.buttons;
	ldown := (b&1) && !(prevb&1);
	lup := !(b&1) && (prevb&1);
	rup := !(b&4) && (prevb&4);
	wup := (b&8) && !(prevb&8);
	wdown := (b&16) && !(prevb&16);
	prevb = b;

	img := win.image;
	if(img == nil)
		return;
	incan := canr.contains(p.xy);
	cx := p.xy.x-canr.min.x;
	cy := p.xy.y-canr.min.y;
	if(incan){
		mcx = cx;
		mcy = cy;
	}

	# sidebar: palette
	if(ldown && p.xy.y >= palr.min.y && p.xy.y < palr.max.y+26 && p.xy.x < palr.max.x){
		i := -1;
		if(p.xy.y < palr.max.y)
			i = ((p.xy.y-palr.min.y)/26)*8 + (p.xy.x-palr.min.x)/26;
		else if(p.xy.x < palr.min.x+24)
			i = 16;	# T cell
		if(i >= 0 && i <= 16){
			c := i;
			if(i == 16)
				c = TRANSP;
			palpick(c);
			redraw();
		}
		return;
	}
	# sidebar: element list
	if(p.xy.x < canr.min.x && p.xy.y >= listr.min.y){
		lh := fonth+2;
		row := listtop + (p.xy.y-listr.min.y)/lh;
		if(wup){
			listtop -= 3;
			if(listtop < 0)
				listtop = 0;
			redraw();
			return;
		}
		if(wdown){
			listtop += 3;
			if(listtop > ne)
				listtop = ne;
			redraw();
			return;
		}
		if(ldown && row >= 0 && row <= ne){
			cur = row;
			status = "insert point moved";
			redraw();
		}
		if(rup && row >= 0 && row < ne){
			elems[row].sel = !elems[row].sel;
			redraw();
		}
		return;
	}

	case mode {
	Mmain =>
		if(ldown && incan){
			i := menuhit(p.xy.y);
			if(i >= 0)
				domain(i);
		}
	Medit =>
		if(ldown && incan){
			i := menuhit(p.xy.y);
			if(i >= 0)
				doedit(i);
		}
	Mtool =>
		toolptr(incan, cx, cy, ldown, lup, rup, b);
	Mpoints =>
		pointsptr(incan, cx, cy, ldown, lup, rup, b);
	Mshiftsel =>
		if(ldown && incan){
			dragging = 1;
			lastcx = cx;
			lastcy = cy;
		}else if(dragging && (b&1)){
			for(i := 0; i < ne; i++)
				if(elems[i].sel)
					shiftelem(elems[i], cx-lastcx, cy-lastcy);
			lastcx = cx;
			lastcy = cy;
			redraw();
		}else if(lup && dragging){
			dragging = 0;
			if(selcnt() == ne)
				selall(0);
			redraw();
		}else if(rup){
			mode = Medit;
			settool(toolname());
			redraw();
		}
	Msetorigin =>
		if(lup && incan){
			addall(Cw/2-cx, Ch/2-cy);
			status = "origin set";
			mode = Medit;
			settool(toolname());
			redraw();
		}else if(rup){
			mode = Medit;
			settool(toolname());
			redraw();
		}
	Msuborigin =>
		if(ldown && incan){
			dragging = 1;
			ax = cx;
			ay = cy;
		}else if(dragging && (b&1) && cur > 0 && elems[cur-1].kind == SSHIFT){
			elems[cur-1].a[0] = cx-ax;
			elems[cur-1].a[1] = cy-ay;
			redraw();
		}else if(lup && dragging){
			dragging = 0;
			mode = Medit;
			settool(toolname());
			redraw();
		}else if(rup){
			mode = Medit;
			settool(toolname());
			redraw();
		}
	Mbitmap =>
		bmptr(incan, cx, cy, b, rup);
	}
}

palpick(c: int)
{
	if(mode == Mbitmap){
		bmink = c;
		return;
	}
	case pickfor {
	Pdither0 =>
		pendbg = c;	# reuse as first dither color
		pickfor = Pdither1;
		status = "second dither color?";
		return;
	Pdither1 =>
		e := mkelem(SDITHER, 2);
		e.a[0] = pendbg&15;
		e.a[1] = c&15;
		ins(e);
		pickfor = Pnone;
		mode = Mmain;
		return;
	Pbgcolor =>
		pendbg = c&15;
		pickfor = Pnone;
		tool = TCAPTURET;
		mode = Mtool;
		phase = 0;
		status = "drag out the capture rect";
		settool(toolname());
		return;
	}
	e := mkelem(SCOLOR, 1);
	e.a[0] = c;
	ins(e);
	if(pickfor == Pcolor){
		pickfor = Pnone;
		mode = Mmain;
	}
}

domain(i: int)
{
	case i {
	0 =>	# Color
		pickfor = Pcolor;
		status = "click a palette color";
	1 =>	# Dither Color
		pickfor = Pdither0;
		status = "click the first dither color";
	2 =>	# Thick
		mode = Mnum;
		numfor = Nthick;
		pbuf = "";
	3 =>	armtool(SPLANARSYM);
	4 =>	armtool(SPT);
	5 =>	armtool(SLINE);
	6 =>	armtool(SARROW);
	7 =>	armtool(SRECT);
	8 =>	armtool(SCIRCLE);
	9 =>	armtool(SELLIPSE);
	10 =>	# Polygon
		mode = Mnum;
		numfor = Nsides;
		pbuf = "";
	11 or 12 or 13 =>	# Text family
		texttool = STEXT;
		if(i == 12)
			texttool = STEXTBOX;
		if(i == 13)
			texttool = STEXTDIAMOND;
		mode = Mtext;
		pbuf = "";
	14 =>	armtool(SFLOOD);
	15 =>	armtool(SFLOODNOT);
	16 =>	armtool(SPOLYLINE);
	17 =>	armtool(SPOLYPT);
	18 =>	armtool(SBSPLINE2);
	19 =>	armtool(SBSPLINE3);
	20 =>	armtool(SBSPLINE2C);
	21 =>	armtool(SBSPLINE3C);
	22 =>	armtool(TCAPTURE);
	23 =>	# transparent capture: pick the bg color first
		pickfor = Pbgcolor;
		status = "color to become transparent?";
	24 =>	# 3D mesh: edited via a .MESH block (see GAP header)
		status = "meshes are edited via a .MESH block: spriteedit file name";
	25 =>	# Convert to BitMap or Edit BitMap
		if(cur > 0 && cur <= ne && elems[cur-1].kind == SBITMAP){
			bmidx = cur-1;
			mode = Mbitmap;
		}else if(cur < ne && elems[cur].kind == SBITMAP){
			bmidx = cur;
			mode = Mbitmap;
		}else
			armtool(TBITMAPED);
	26 =>	ins(mkelem(STRANSON, 0));
	27 =>	ins(mkelem(STRANSOFF, 0));
	28 =>	mode = Medit;
	29 =>	exitsave();
	30 =>	abort();
	}
	settool(toolname());
	redraw();
}

doedit(i: int)
{
	case i {
	0 =>	# Select/Unselect All
		if(selcnt() == 0)
			selall(1);
		else
			selall(0);
	1 or 2 or 3 or 4 or 5 or 6 =>
		pmode = i-1;
		mode = Mpoints;
		buildcps();
		# preload selection flags from the elements
		for(j := 0; j < ncp; j++)
			cpsel[j] = elems[cpe[j]].sel;
		dragging = 0;
		phase = 0;
	7 =>	# Shift Selected Elems
		if(selcnt() == 0)
			selall(1);
		mode = Mshiftsel;
		dragging = 0;
	8 =>	# Transform Selected Elems
		mode = Mxform;
		pbuf = "";
	9 =>	mode = Msetorigin;
	10 =>	# Insert Shift SubOrigin
		e := mkelem(SSHIFT, 2);
		ins(e);
		mode = Msuborigin;
		dragging = 0;
	11 =>	# Edit as Text: the on-disk form IS the text form
		savefile();
		status = "saved; edit "+path+" and press l to reload";
	12 =>	# Insert Sprite File (Insert Clip's analog)
		mode = Mfile;
		pbuf = "";
	13 =>	delsel();
	14 =>	mode = Mmain;
	15 =>	exitsave();
	16 =>	abort();
	}
	settool(toolname());
	redraw();
}

armtool(t: int)
{
	tool = t;
	mode = Mtool;
	phase = 0;
	pvon = 0;
	capon = 0;
	settool(toolname());
}

toolptr(incan, cx, cy, ldown, lup, rup: int, b: int)
{
	(ex, ey) := ecoord(cx, cy);
	case tool {
	SLINE or SARROW or SRECT or SPLANARSYM =>
		if(ldown && incan){
			phase = 1;
			ax = ex;
			ay = ey;
			pv = mkelem(tool, 4);
			pv.a[0] = ax; pv.a[1] = ay;
			pv.a[2] = ex; pv.a[3] = ey;
			pvon = 1;
			redraw();
		}else if(phase == 1 && (b&1)){
			pv.a[2] = ex;
			pv.a[3] = ey;
			if(tool == SRECT){
				pv.a[0] = ax; pv.a[1] = ay;
				if(ex < ax){ pv.a[0] = ex; pv.a[2] = ax; }
				if(ey < ay){ pv.a[1] = ey; pv.a[3] = ay; }
			}
			redraw();
		}else if(lup && phase == 1){
			phase = 0;
			pvon = 0;
			ins(pv);
			if(tool == SPLANARSYM)
				backtomenu();
			redraw();
		}else if(rup){
			if(tool == SPLANARSYM){
				# right-click turns symmetry off (empty elem)
				ins(mkelem(SPLANARSYM, 4));
			}
			backtomenu();
			redraw();
		}
	SCIRCLE =>
		if(ldown && incan){
			phase = 1;
			ax = ex;
			ay = ey;
			pv = mkelem(SCIRCLE, 3);
			pv.a[0] = ax;
			pv.a[1] = ay;
			pvon = 1;
			redraw();
		}else if(phase == 1 && (b&1)){
			dx := real(ex-ax);
			dy := real(ey-ay);
			pv.a[2] = int math->sqrt(dx*dx+dy*dy);
			redraw();
		}else if(lup && phase == 1){
			phase = 0;
			pvon = 0;
			ins(pv);
			redraw();
		}else if(rup){
			backtomenu();
			redraw();
		}
	SELLIPSE or SPOLYGON =>
		if(phase == 0 && ldown && incan){
			phase = 1;
			ax = ex;
			ay = ey;
			na := 4;
			if(tool == SPOLYGON)
				na = 5;
			pv = mkelem(tool, na);
			pv.a[0] = ax;
			pv.a[1] = ay;
			if(tool == SPOLYGON)
				pv.a[4] = sides;
			pvon = 1;
			redraw();
		}else if(phase == 1 && (b&1)){
			pv.a[0] = (ax+ex)/2;
			pv.a[1] = (ay+ey)/2;
			w := ex-ax; if(w < 0) w = -w;
			h := ey-ay; if(h < 0) h = -h;
			pv.a[2] = w/2;
			pv.a[3] = h/2;
			redraw();
		}else if(lup && phase == 1){
			phase = 2;
			a2 = math->atan2(real(ey-pv.a[1]), real(ex-pv.a[0]));
			if(pv.a[2] < pv.a[3])
				a2 -= Math->Pi/2.0;
			redraw();
		}else if(phase == 2 && lup){
			phase = 0;
			pvon = 0;
			ins(pv);
			if(tool == SPOLYGON)
				backtomenu();
			redraw();
		}else if(phase == 2 && !(b&1)){
			a1 := math->atan2(real(ey-pv.a[1]), real(ex-pv.a[0]));
			pv.ang = a1-a2;
			redraw();
		}else if(rup && phase == 0){
			backtomenu();
			redraw();
		}
	SPT or SFLOOD or SFLOODNOT =>
		if(ldown && incan){
			e := mkelem(tool, 2);
			e.a[0] = ex;
			e.a[1] = ey;
			ins(e);
			redraw();
		}else if(rup){
			backtomenu();
			redraw();
		}
	SPOLYLINE or SBSPLINE2 or SBSPLINE3 or SBSPLINE2C or SBSPLINE3C =>
		# the LAST point of the preview is a live cursor point;
		# clicks freeze it and start a new one
		per := 2;
		if(tool != SPOLYLINE)
			per = 3;
		if(lup && incan){
			if(!pvon){
				pv = mkelem(tool, 0);
				pv.pts = array[per] of {* => 0};
				pv.pts[0] = ex;
				pv.pts[1] = ey;
				pvon = 1;
			}
			np := array[len pv.pts+per] of {* => 0};
			np[0:] = pv.pts;
			np[len pv.pts] = ex;
			np[len pv.pts+1] = ey;
			pv.pts = np;
			redraw();
		}else if(pvon && incan){
			n := len pv.pts;
			pv.pts[n-per] = ex;
			pv.pts[n-per+1] = ey;
			redraw();
		}else if(rup){
			if(pvon){
				# drop the live cursor point
				pv.pts = pv.pts[0:len pv.pts-per];
				min := 2;
				if(tool != SPOLYLINE)
					min = 3;
				if(len pv.pts/per >= min)
					ins(pv);
				else
					status = "too few points; discarded";
				pvon = 0;
			}else
				backtomenu();
			redraw();
		}
	SPOLYPT =>
		if(ldown && incan){
			pv = mkelem(SPOLYPT, 3);
			pv.a[1] = ex;
			pv.a[2] = ey;
			pv.data = array[64] of {* => byte 0};
			pv.a[0] = 0;
			lastcx = ex;
			lastcy = ey;
			pvon = 1;
			phase = 1;
			redraw();
		}else if(phase == 1 && (b&1)){
			(lastcx, lastcy) = walkappend(pv, ex, ey, lastcx, lastcy);
			redraw();
		}else if(lup && phase == 1){
			phase = 0;
			pvon = 0;
			ins(pv);
			redraw();
		}else if(rup){
			backtomenu();
			redraw();
		}
	TCAPTURE or TCAPTURET or TBITMAPED =>
		if(ldown && incan){
			phase = 1;
			capx0 = capx1 = cx;
			capy0 = capy1 = cy;
			capon = 1;
			redraw();
		}else if(phase == 1 && (b&1)){
			capx1 = cx;
			capy1 = cy;
			redraw();
		}else if(lup && phase == 1){
			phase = 0;
			capon = 0;
			# capture from the current replay (sans preview)
			work[0:] = blank;
			replay(work);
			tc := -1;
			if(tool == TCAPTURET)
				tc = pendbg;
			e := capture(capx0, capy0, capx1, capy1, tc);
			if(e != nil){
				ins(e);
				if(tool == TBITMAPED){
					bmidx = cur-1;
					mode = Mbitmap;
					settool(toolname());
				}else
					backtomenu();
			}
			redraw();
		}else if(rup){
			backtomenu();
			redraw();
		}
	STEXT or STEXTBOX or STEXTDIAMOND =>
		if(pvon && !(b&1)){
			(pv.a[0], pv.a[1]) = ecoord(cx, cy);
			redraw();
		}
		if(lup && pvon){
			pvon = 0;
			ins(pv);
			backtomenu();
			redraw();
		}else if(rup){
			pvon = 0;
			backtomenu();
			redraw();
		}
	}
}

backtomenu()
{
	mode = Mmain;
	phase = 0;
	pvon = 0;
	capon = 0;
	pickfor = Pnone;
	settool(toolname());
}

pointsptr(incan, cx, cy, ldown, lup, rup: int, b: int)
{
	if(rup){
		# leaving points mode: write selection back to the elements
		for(i := 0; i < ncp; i++)
			if(cpsel[i])
				elems[cpe[i]].sel = 1;
		mode = Medit;
		dragging = 0;
		settool(toolname());
		redraw();
		return;
	}
	case pmode {
	PMsel or PMunsel =>
		if(ldown && incan && ncp > 0){
			i := cpnearest(cx, cy);
			if(i >= 0){
				v := pmode == PMsel;
				cpsel[i] = v;
				elems[cpe[i]].sel = v;
				cur = cpe[i];
				redraw();
			}
		}
	PMselrect or PMunselrect =>
		if(ldown && incan){
			dragging = 1;
			capx0 = capx1 = cx;
			capy0 = capy1 = cy;
			redraw();
		}else if(dragging && (b&1)){
			capx1 = cx;
			capy1 = cy;
			redraw();
		}else if(lup && dragging){
			dragging = 0;
			x0 := capx0; x1 := capx1;
			if(x1 < x0){ t := x0; x0 = x1; x1 = t; }
			y0 := capy0; y1 := capy1;
			if(y1 < y0){ t := y0; y0 = y1; y1 = t; }
			v := pmode == PMselrect;
			for(i := 0; i < ncp; i++){
				(x, y) := cppos(i);
				if(x >= x0 && x <= x1 && y >= y0 && y <= y1){
					cpsel[i] = v;
					elems[cpe[i]].sel = v;
				}
			}
			redraw();
		}
	PMshift =>
		if(ldown && incan && ncp > 0){
			i := cpnearest(cx, cy);
			if(i >= 0){
				cpsel[i] = 1;
				elems[cpe[i]].sel = 1;
				dragging = 1;
				lastcx = cx;
				lastcy = cy;
				redraw();
			}
		}else if(dragging && (b&1)){
			cpmovesel(cx-lastcx, cy-lastcy);
			lastcx = cx;
			lastcy = cy;
			redraw();
		}else if(lup && dragging){
			dragging = 0;
			for(i := 0; i < ncp; i++){
				cpsel[i] = 0;
				elems[cpe[i]].sel = 0;
			}
			redraw();
		}
	PMshiftrect =>
		if(ldown && incan && !dragging && phase == 0){
			dragging = 1;
			capx0 = capx1 = cx;
			capy0 = capy1 = cy;
			redraw();
		}else if(dragging && (b&1) && phase == 0){
			capx1 = cx;
			capy1 = cy;
			redraw();
		}else if(lup && dragging && phase == 0){
			dragging = 0;
			x0 := capx0; x1 := capx1;
			if(x1 < x0){ t := x0; x0 = x1; x1 = t; }
			y0 := capy0; y1 := capy1;
			if(y1 < y0){ t := y0; y0 = y1; y1 = t; }
			for(i := 0; i < ncp; i++){
				(x, y) := cppos(i);
				if(x >= x0 && x <= x1 && y >= y0 && y <= y1)
					cpsel[i] = 1;
			}
			phase = 1;
			status = "drag to move the selected points";
			redraw();
		}else if(ldown && incan && phase == 1){
			dragging = 1;
			lastcx = cx;
			lastcy = cy;
		}else if(dragging && (b&1) && phase == 1){
			cpmovesel(cx-lastcx, cy-lastcy);
			lastcx = cx;
			lastcy = cy;
			redraw();
		}else if(lup && dragging && phase == 1){
			dragging = 0;
			phase = 0;
			for(i := 0; i < ncp; i++)
				cpsel[i] = 0;
			redraw();
		}
	}
}

shiftelem(e: ref Elem, dx, dy: int)
{
	case e.kind {
	SLINE or SARROW or SPLANARSYM or SRECT or SROTRECT =>
		e.a[0] += dx; e.a[1] += dy;
		e.a[2] += dx; e.a[3] += dy;
	SPT or SFLOOD or SFLOODNOT or STEXT or STEXTBOX or
	STEXTDIAMOND or SCIRCLE or SBITMAP or SELLIPSE or SPOLYGON or SSHIFT =>
		e.a[0] += dx; e.a[1] += dy;
	SPOLYLINE =>
		for(j := 0; j < len e.pts; j += 2){
			e.pts[j] += dx;
			e.pts[j+1] += dy;
		}
	SBSPLINE2 or SBSPLINE2C or SBSPLINE3 or SBSPLINE3C =>
		for(j := 0; j < len e.pts; j += 3){
			e.pts[j] += dx;
			e.pts[j+1] += dy;
		}
	SPOLYPT =>
		e.a[1] += dx; e.a[2] += dy;
	}
}

bmptr(incan, cx, cy: int, b: int, rup: int)
{
	if(rup || bmidx < 0 || bmidx >= ne){
		mode = Mmain;
		settool(toolname());
		redraw();
		return;
	}
	if(!(b&(1|4)) || !incan)
		return;
	e := elems[bmidx];
	w := e.a[2];
	h := e.a[3];
	cell := (canr.dx()-16)/w;
	if((canr.dy()-16)/h < cell)
		cell = (canr.dy()-16)/h;
	if(cell < 2)
		cell = 2;
	if(cell > 24)
		cell = 24;
	gx := (canr.dx()-w*cell)/2;
	gy := (canr.dy()-h*cell)/2;
	x := (cx-gx)/cell;
	y := (cy-gy)/cell;
	if(x < 0 || x >= w || y < 0 || y >= h)
		return;
	stride := (w+7)&~7;
	v := bmink;
	if(b&4)
		v = TRANSP;
	if(int e.data[y*stride+x] != v){
		e.data[y*stride+x] = byte v;
		redraw();
	}
}

# ---------- .MESH block mode (SpriteMeshEd's echo) ----------

parse_mesh(s: string, a: int)
{
	eol := findstr(s, "\n", a);
	end := findstr(s, ".ENDMESH", eol+1);
	if(eol < 0 || end < 0){
		status = "bad mesh block";
		return;
	}
	endline := findstr(s, "\n", end);
	if(endline < 0)
		endline = len s;
	else
		endline++;
	prefix = s[0:a];
	suffix = s[endline:];
	(nh, hdr) := sys->tokenize(s[a:eol], " \t\r");
	if(nh != 4){
		status = "bad mesh header";
		return;
	}
	nv = int hd tl tl hdr;
	nf = int hd tl tl tl hdr;
	if(nv < 0 || nv > 4096 || nf < 0 || nf > 8192){
		status = "mesh too large";
		return;
	}
	vx = array[nv] of int;
	vy = array[nv] of int;
	vz = array[nv] of int;
	fa = array[nf] of int;
	fb = array[nf] of int;
	fc = array[nf] of int;
	fcol = array[nf] of int;
	(nil, lines) := sys->tokenize(s[eol+1:end], "\n");
	vi := 0;
	fi := 0;
	for(; lines != nil; lines = tl lines){
		(nil, t) := sys->tokenize(hd lines, " \t\r");
		if(t == nil)
			continue;
		if(hd t == "v" && len t == 4 && vi < nv){
			t = tl t; vx[vi] = int hd t;
			t = tl t; vy[vi] = int hd t;
			t = tl t; vz[vi++] = int hd t;
		}else if(hd t == "f" && len t == 5 && fi < nf){
			t = tl t; fcol[fi] = int hd t;
			if(fcol[fi] >= 0 && fcol[fi] < 16)
				fcol[fi] = pal[fcol[fi]];
			t = tl t; fa[fi] = int hd t;
			t = tl t; fb[fi] = int hd t;
			t = tl t; fc[fi++] = int hd t;
		}
	}
	if(vi != nv || fi != nf){
		status = "truncated mesh";
		return;
	}
	meshmode = 1;
	selected = -1;
	pick0 = pick1 = pick2 = -1;
	status = "loaded mesh";
}

save_mesh()
{
	s := prefix+sys->sprint(".MESH %s %d %d\n", name, nv, nf);
	for(i := 0; i < nv; i++)
		s += sys->sprint("v %d %d %d\n", vx[i], vy[i], vz[i]);
	for(i = 0; i < nf; i++)
		s += sys->sprint("f %d %d %d %d\n", fcol[i], fa[i], fb[i], fc[i]);
	s += ".ENDMESH\n"+suffix;
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil){
		status = sys->sprint("save: %r");
		return;
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b){
		status = sys->sprint("save: %r");
		return;
	}
	wrote = 1;
	status = "saved mesh";
}

meshkbd(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		save_mesh();
		win.wmctl("exit");
	'A' =>
		abort();
	's' or 'S' =>
		save_mesh();
		redraw_mesh();
	'\t' =>
		plane = (plane+1)%3;
		redraw_mesh();
	' ' =>
		remember_vertex();
		redraw_mesh();
	't' or 'T' =>
		add_face();
		redraw_mesh();
	'v' or 'V' =>
		add_vertex_at(lastx, lasty);
		redraw_mesh();
	'g' or 'G' =>
		meshgrid = !meshgrid;
		redraw_mesh();
	'n' or 'N' =>
		nv = nf = 0;
		vx = vy = vz = array[0] of int;
		fa = fb = fc = fcol = array[0] of int;
		selected = pick0 = pick1 = pick2 = -1;
		status = "cleared mesh";
		redraw_mesh();
	}
}

add_vertex_at(px, py: int)
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	sc := meshscale(w, h);
	lc := o.x+w/4;
	cy := o.y+(Topb+h-36)/2;
	x := 0;
	y := 0;
	z := 0;
	if(sc > 0.0){
		u := int (real(px-lc)/sc);
		v := int (real(cy-py)/sc);
		case plane {
		0 =>	x = u; y = v;
		1 =>	x = u; z = v;
		* =>	z = u; y = v;
		}
	}
	nx := array[nv+1] of int;
	ny := array[nv+1] of int;
	nz := array[nv+1] of int;
	for(i := 0; i < nv; i++){
		nx[i] = vx[i];
		ny[i] = vy[i];
		nz[i] = vz[i];
	}
	nx[nv] = x;
	ny[nv] = y;
	nz[nv] = z;
	vx = nx;
	vy = ny;
	vz = nz;
	selected = nv;
	nv++;
	status = "added vertex";
}

remember_vertex()
{
	if(selected < 0)
		return;
	pick0 = pick1;
	pick1 = pick2;
	pick2 = selected;
	status = sys->sprint("face vertices %d %d %d", pick0, pick1, pick2);
}

add_face()
{
	if(pick0 < 0 || pick1 < 0 || pick2 < 0){
		status = "select three vertices with Space";
		return;
	}
	na := array[nf+1] of int;
	nb := array[nf+1] of int;
	nc := array[nf+1] of int;
	ncl := array[nf+1] of int;
	for(i := 0; i < nf; i++){
		na[i] = fa[i];
		nb[i] = fb[i];
		nc[i] = fc[i];
		ncl[i] = fcol[i];
	}
	na[nf] = pick0;
	nb[nf] = pick1;
	nc[nf] = pick2;
	ncl[nf] = meshink;
	fa = na;
	fb = nb;
	fc = nc;
	fcol = ncl;
	nf++;
	status = "added triangle";
}

ortho(i, cx, cy: int, scale: real): Point
{
	case plane {
	0 =>	return Point(cx+int(real vx[i]*scale), cy-int(real vy[i]*scale));
	1 =>	return Point(cx+int(real vx[i]*scale), cy-int(real vz[i]*scale));
	* =>	return Point(cx+int(real vz[i]*scale), cy-int(real vy[i]*scale));
	}
}

meshpreview(i, cx, cy: int, scale: real): Point
{
	x := real vx[i];
	y := real vy[i];
	z := real vz[i];
	return Point(cx+int((0.78*x-0.62*z)*scale),
		cy-int((y+0.35*x+0.44*z)*scale));
}

meshscale(w, h: int): real
{
	m := 1;
	for(i := 0; i < nv; i++){
		if(iabs(vx[i]) > m) m = iabs(vx[i]);
		if(iabs(vy[i]) > m) m = iabs(vy[i]);
		if(iabs(vz[i]) > m) m = iabs(vz[i]);
	}
	s := real (h/2-36)/real m;
	if(real(w/4-18)/real m < s)
		s = real(w/4-18)/real m;
	return s;
}

redraw_mesh()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, palimg[LTGRAY], nil, Point(0, 0));
	mid := o.x+w/2;
	img.line(Point(mid, o.y+Topb), Point(mid, o.y+h-36), 0, 0, 0, palimg[DKGRAY], Point(0,0));
	sc := meshscale(w, h);
	lc := o.x+w/4;
	rc := o.x+3*w/4;
	cy := o.y+(Topb+h-36)/2;
	if(meshgrid && sc > 0.0){
		step := int (10.0*sc);
		if(step > 3)
			for(g := -10; g <= 10; g++){
				img.line(Point(lc+g*step, o.y+Topb), Point(lc+g*step, o.y+h-36),
					0, 0, 0, palimg[LTGRAY], Point(0,0));
				gy := cy+g*step;
				if(gy > o.y+Topb && gy < o.y+h-36)
					img.line(Point(o.x, gy), Point(mid, gy), 0, 0, 0, palimg[LTGRAY], Point(0,0));
			}
	}
	for(i := 0; i < nf; i++){
		if(fa[i] < 0 || fa[i] >= nv || fb[i] < 0 || fb[i] >= nv || fc[i] < 0 || fc[i] >= nv)
			continue;
		p := array[] of {meshpreview(fa[i], rc, cy, sc), meshpreview(fb[i], rc, cy, sc),
			meshpreview(fc[i], rc, cy, sc)};
		fcimg := colour(fcol[i]);
		img.fillpoly(p, 0, fcimg, Point(0,0));
		pa := ortho(fa[i], lc, cy, sc);
		pb := ortho(fb[i], lc, cy, sc);
		pc := ortho(fc[i], lc, cy, sc);
		img.line(pa, pb, 0, 0, 0, fcimg, Point(0,0));
		img.line(pb, pc, 0, 0, 0, fcimg, Point(0,0));
		img.line(pc, pa, 0, 0, 0, fcimg, Point(0,0));
	}
	for(i = 0; i < nv; i++){
		p := ortho(i, lc, cy, sc);
		cc := WHITE;
		if(i == selected)
			cc = YELLOW;
		img.fillellipse(p, 3, 3, palimg[cc], Point(0,0));
	}
	# palette row instead of RGB sliders: mesh ink is a TempleOS color
	py := o.y+h-30;
	for(i = 0; i < 16; i++){
		r := Rect((o.x+4+i*26, py), (o.x+4+i*26+24, py+24));
		img.draw(r, palimg[i], nil, Point(0,0));
		if(pal[i] == meshink)
			boxo(img, r, WHITE);
		else
			boxo(img, r, BLACK);
	}
	planes := array[] of {"XY/front", "XZ/top", "ZY/side"};
	txt(img, o.x+4, o.y+2, BLACK,
		sys->sprint("%s [%s] mesh %dv/%df -- %s", path, name, nv, nf, status));
	txt(img, o.x+4, o.y+2+fonth, DKGRAY,
		planes[plane]+"  drag:LMB mark:Space tri:T vertex:V plane:Tab grid:G save:S");
	img.flush(Draw->Flushnow);
}

mesh_pointer(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	b := p.buttons;
	ldown := (b&1) && !(prevb&1);
	prevb = b;
	lastx = p.xy.x;
	lasty = p.xy.y;
	if(ldown && p.xy.y >= o.y+h-30){
		i := (p.xy.x-o.x-4)/26;
		if(i >= 0 && i < 16){
			meshink = pal[i];
			if(selected >= 0)
				for(j := 0; j < nf; j++)
					if(fa[j] == selected || fb[j] == selected || fc[j] == selected)
						fcol[j] = meshink;
			status = "mesh ink "+colname[i];
			redraw_mesh();
		}
		return;
	}
	lc := o.x+w/4;
	cy := o.y+(Topb+h-36)/2;
	sc := meshscale(w, h);
	if(!(b&1)){
		dragging = 0;
		return;
	}
	if(p.xy.x >= o.x+w/2)
		return;
	if(!dragging){
		best := 1000000;
		selected = -1;
		for(i := 0; i < nv; i++){
			q := ortho(i, lc, cy, sc);
			dx := q.x-p.xy.x;
			dy := q.y-p.xy.y;
			d := dx*dx+dy*dy;
			if(d < best){
				best = d;
				selected = i;
			}
		}
		if(best > 144)
			selected = -1;
		dragging = 1;
		lastcx = p.xy.x;
		lastcy = p.xy.y;
		redraw_mesh();
		return;
	}
	if(selected < 0 || sc == 0.0)
		return;
	dx := int(real(p.xy.x-lastcx)/sc);
	dy := int(real(p.xy.y-lastcy)/sc);
	if(dx == 0 && dy == 0)
		return;
	case plane {
	0 =>	vx[selected] += dx; vy[selected] -= dy;
	1 =>	vx[selected] += dx; vz[selected] -= dy;
	* =>	vz[selected] += dx; vy[selected] -= dy;
	}
	lastcx = p.xy.x;
	lastcy = p.xy.y;
	status = "modified mesh";
	redraw_mesh();
}

iabs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
}
