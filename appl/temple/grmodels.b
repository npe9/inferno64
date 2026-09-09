implement Grmodels;

# TempleOS Apps/GrModels (Models/BallGen/ManGen) — CSprite mesh GENERATOR suite.
#
# Faithful workflow: a DolDoc-style button page (Models) offers Man/Ball;
# each generator shows its DocForm parameter form (BallGen: 3 fields with
# BDCorrect halving; ManGen: 28 fields, 12 dimensions + 16 joint angles with
# MDCorrect angle accumulation), then PopUpColorLighting picker(s) (ball face
# color; man Shirt/Pants/Skin/Shoes), builds the mesh with the original's
# exact geometry (stagger-quad UV sphere with AddVertex dedup; articulated
# AddBox chain rotated Rz then Ry then Rx per Mat4x4RotZ/Y/X pre-multiply),
# displays it shaded by a transliteration of DCLighting (light (1,1,1)/sqrt(3),
# probability dither BLACK..color..color^8 with the TWO_SIDED/HALF_RANGE
# flags), prints the vertex count (ball), and loops "Do another" Y/N.
#
# GAP: TempleOS embeds the generated CSprite in the DolDoc page with
#   Sprite(res,"$$SP,...,BI=%d$$") for cut-and-paste into other documents;
#   there is no DolDoc clipboard here, so the byte-identical CSprite stream
#   (SPT_MESH element, little-endian, exactly as Ball2CSprite/Man2CSprite
#   lay it out) is written to ./grmodels.csprite instead.
# GAP: TempleOS's fixed-point (<<32) Mat4x4 arithmetic is emulated with real
#   arithmetic rounded to ints; vertex coords can differ from TempleOS by 1.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";
include "grpalette.m";
	grpal: Grpalette;

Grmodels: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# TempleOS constants
T_MAN: con 0;
T_BALL: con 1;
ROPFHALF: con 16r1000;		# ROPF_HALF_RANGE_COLOR
ROPFTWOSIDED: con 16r2000;	# ROPF_TWO_SIDED
SPTMESH: con 24;
MAXV: con 1024;			# VERTICES_NUM
MAXT: con 1024;			# TRIS_NUM

# app states
SMENU, SFORM, SCOLOR, SRESULT: con iota;

Mesh: adt {
	nv: int;
	vx, vy, vz: array of int;	# CD3I32 (integer coords, as stored)
	nt: int;
	tc, t0, t1, t2: array of int;	# CMeshTri: color (with ROPF flags), nums
};

Field: adt {
	label: string;
	val: string;
	isint: int;
	vw: int;		# value width in 8x8 cells (%8.3f -> 8, %5d -> 5)
	r: Rect;		# value box for mouse
};

win: ref Window;
disp: ref Display;
tosfont: ref Font;
ink: array of ref Image;

# the EXACT TempleOS 16-color palette, index = TempleOS color
palette: array of int;

# TempleOS ST_COLORS define list
colornames := array[] of {
	"BLACK", "BLUE", "GREEN", "CYAN", "RED", "PURPLE", "BROWN", "LTGRAY",
	"DKGRAY", "LTBLUE", "LTGREEN", "LTCYAN", "LTRED", "LTPURPLE", "YELLOW", "WHITE"
};

state := SMENU;
menusel := 0;			# 0 Man, 1 Ball (order of the Models buttons)
gmode := T_MAN;
fields: array of Field;
fsel := 0;

# parsed generator parameters
bd_rad := 20.0;
bd_lon := 16;
bd_lat := 8;
mdv: array of real;

# color picking
pickhdrs: array of string;
picked: array of int;
pickidx := 0;
picksel := 0;
npents := 0;
pents_r: array of Rect;
pents_v: array of int;
blink := 0;
tickn := 0;

mesh: ref Mesh;
savedmsg := "";

# result viewer (port adaptation; TempleOS shows the sprite statically)
yaw := 0.0;
pitch := 0.0;
zoom := 1.0;
drag := 0;
last_mx := 0;
last_my := 0;
prevb := 0;

# menu button rects
manr, ballr: Rect;

# dither tiles: 4x4 Bayer ordered dither between two palette colors
tiles: array of ref Image;
bayer4 := array[] of { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	palette = grpal->values();
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS GrModels", Wmclient->Appl);
	disp = win.display;
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = disp.color(palette[i]);
	tiles = array[16*16*17] of ref Image;

	tosfont = Font.open(disp, "/fonts/temple/temple.font");
	if(tosfont == nil)
		tosfont = Font.open(disp, "*default*");

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();

	# no animate task in the original; the 40ms tick only drives the
	# DolDoc $$BK,1$$ blink of the ManGen picker headers (~240ms toggle,
	# TempleOS winmgr blinks at 250ms) and drag redraw in the viewer
	ticks := chan of int;
	spawn timer(ticks, 40);
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
		key(k);
	<-ticks =>
		tickn++;
		if(state == SRESULT && drag)
			redraw();
		if(state == SCOLOR && pickhdrs[pickidx] != nil && tickn % 6 == 0){
			blink++;
			redraw();
		}
	}
}

key(k: int)
{
	case state {
	SMENU =>
		case k {
		Keyboard->Esc or 'q' or 'Q' =>
			exit;
		Keyboard->Up or Keyboard->Down or '\t' =>
			menusel ^= 1;
			redraw();
		'\n' =>
			startform(menusel);
		'm' or 'M' =>
			startform(T_MAN);
		'b' or 'B' =>
			startform(T_BALL);
		}
	SFORM =>
		formkey(k);
	SCOLOR =>
		colorkey(k);
	SRESULT =>
		case k {
		'y' or 'Y' =>
			state = SFORM;	# loop: DocForm again, edits retained
			redraw();
		'n' or 'N' or Keyboard->Esc =>
			state = SMENU;
			redraw();
		'+' or '=' =>
			zoom *= 1.1;
			redraw();
		'-' or '_' =>
			zoom /= 1.1;
			if(zoom < 0.2)
				zoom = 0.2;
			redraw();
		Keyboard->Left =>
			yaw -= 0.08; redraw();
		Keyboard->Right =>
			yaw += 0.08; redraw();
		Keyboard->Up =>
			pitch += 0.08; redraw();
		Keyboard->Down =>
			pitch -= 0.08; redraw();
		}
	}
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	press := (p.buttons & 1) != 0 && (prevb & 1) == 0;
	case state {
	SMENU =>
		if(press){
			if(manr.contains(p.xy))
				startform(T_MAN);
			else if(ballr.contains(p.xy))
				startform(T_BALL);
		}
	SFORM =>
		if(press){
			for(i := 0; i < len fields; i++)
				if(fields[i].r.contains(p.xy)){
					fsel = i;
					redraw();
					break;
				}
		}
	SCOLOR =>
		if(press){
			for(i := 0; i < npents; i++)
				if(pents_r[i].contains(p.xy)){
					picksel = i;
					choose(pents_v[i]);
					break;
				}
		}
	SRESULT =>
		x := p.xy.x - img.r.min.x;
		y := p.xy.y - img.r.min.y;
		if((p.buttons & 1) != 0){
			if(!drag){
				drag = 1;
				last_mx = x;
				last_my = y;
			}else{
				yaw += real(x - last_mx) * 0.01;
				pitch += real(y - last_my) * 0.01;
				last_mx = x;
				last_my = y;
			}
		}else
			drag = 0;
	}
	prevb = p.buttons;
}

# ---------- forms (DocForm) ----------

mkfield(label: string, v: real, isint, vw: int): Field
{
	s: string;
	if(isint)
		s = sys->sprint("%d", int v);
	else
		s = sys->sprint("%.3f", v);
	return Field(label, s, isint, vw, Rect((0,0),(0,0)));
}

startform(t: int)
{
	gmode = t;
	if(t == T_BALL){
		# BDInit defaults
		fields = array[] of {
			mkfield("Radius:", 20.0, 0, 8),
			mkfield("Longitude Faces:", 16.0, 1, 5),
			mkfield("Lattitude Rings:", 8.0, 1, 5)
		};
	}else{
		# MDInit defaults
		fields = array[] of {
			mkfield("Head Radius:", 5.0, 0, 8),
			mkfield("Torso Length:", 35.0, 0, 8),
			mkfield("Arm Length:", 30.0, 0, 8),
			mkfield("Hand Length:", 8.0, 0, 8),
			mkfield("Leg Length:", 32.0, 0, 8),
			mkfield("Foot Length:", 16.0, 0, 8),
			mkfield("Torso Width:", 20.0, 0, 8),
			mkfield("Torso Depth:", 10.0, 0, 8),
			mkfield("Arm Radius:", 3.5, 0, 8),
			mkfield("Hand Radius:", 2.0, 0, 8),
			mkfield("Leg Radius:", 4.0, 0, 8),
			mkfield("Foot Radius:", 3.0, 0, 8),
			mkfield("R.ShoulderFront/BackAngle:", 30.0, 0, 8),
			mkfield("L.ShoulderFront/BackAngle:", -30.0, 0, 8),
			mkfield("R.HipFront/BackAngle:", -45.0, 0, 8),
			mkfield("L.HipFront/BackAngle:", 45.0, 0, 8),
			mkfield("R.ShoulderSideAngle:", 10.0, 0, 8),
			mkfield("L.ShoulderSideAngle:", 10.0, 0, 8),
			mkfield("R.HipSideAngle:", -5.0, 0, 8),
			mkfield("L.HipSideAngle:", -5.0, 0, 8),
			mkfield("R.ElbowAngle:", 30.0, 0, 8),
			mkfield("L.ElbowAngle:", 0.0, 0, 8),
			mkfield("R.KneeAngle:", 0.0, 0, 8),
			mkfield("L.KneeAngle:", 30.0, 0, 8),
			mkfield("R.WristAngle:", 0.0, 0, 8),
			mkfield("L.WristAngle:", 0.0, 0, 8),
			mkfield("R.AnkleAngle:", 0.0, 0, 8),
			mkfield("L.AnkleAngle:", 0.0, 0, 8)
		};
	}
	fsel = 0;
	state = SFORM;
	redraw();
}

formkey(k: int)
{
	case k {
	Keyboard->Esc =>
		formok();		# ESC = accept, like DocForm
	Keyboard->Del or 'q' or 'Q' =>
		state = SMENU;		# abort = DocForm FALSE -> generator returns
		redraw();
	'\n' or '\t' or Keyboard->Down =>
		fsel = (fsel + 1) % len fields;
		redraw();
	Keyboard->Up =>
		fsel = (fsel + len fields - 1) % len fields;
		redraw();
	'\b' =>
		v := fields[fsel].val;
		if(len v > 0)
			fields[fsel].val = v[0:len v - 1];
		redraw();
	21 =>				# ctl-u clears the field
		fields[fsel].val = "";
		redraw();
	* =>
		if((k >= '0' && k <= '9') || k == '.' || k == '-' || k == '+'){
			v := fields[fsel].val;
			if(len v < 12){
				v[len v] = k;
				fields[fsel].val = v;
				redraw();
			}
		}
	}
}

formok()
{
	if(gmode == T_BALL){
		bd_rad = real fields[0].val;
		bd_lon = int fields[1].val;
		bd_lat = int fields[2].val;
		pickhdrs = array[1] of string;	# PopUpColorLighting() with no header
	}else{
		mdv = array[28] of real;
		for(i := 0; i < 28; i++)
			mdv[i] = real fields[i].val;
		pickhdrs = array[] of { "Shirt", "Pants", "Skin", "Shoes" };
	}
	picked = array[len pickhdrs] of int;
	pickidx = 0;
	picksel = 0;
	blink = 0;
	state = SCOLOR;
	redraw();
}

# ---------- color picker (PopUpColorLighting) ----------

colorkey(k: int)
{
	case k {
	Keyboard->Esc =>
		state = SMENU;		# c<0: whole generator returns NULL
		redraw();
	'\n' =>
		choose(pents_v[picksel]);
	Keyboard->Up =>
		if(picksel >= 2){
			picksel -= 2;
			redraw();
		}
	Keyboard->Down =>
		if(picksel + 2 < npents){
			picksel += 2;
			redraw();
		}
	Keyboard->Left =>
		if(picksel % 2 == 1){
			picksel--;
			redraw();
		}
	Keyboard->Right =>
		if(picksel % 2 == 0 && picksel + 1 < npents){
			picksel++;
			redraw();
		}
	}
}

choose(v: int)
{
	picked[pickidx++] = v;
	picksel = 0;
	blink = 0;
	if(pickidx >= len picked)
		generate();
	else
		redraw();
}

# ---------- mesh construction (exact transliterations) ----------

newmesh()
{
	mesh = ref Mesh(0,
		array[MAXV] of int, array[MAXV] of int, array[MAXV] of int,
		0,
		array[MAXT] of int, array[MAXT] of int,
		array[MAXT] of int, array[MAXT] of int);
}

# BallGen AddVertex: integer coords, dedup by exact equality
addvb(x, y, z: int): int
{
	m := mesh;
	for(i := 0; i < m.nv; i++)
		if(m.vx[i] == x && m.vy[i] == y && m.vz[i] == z)
			return i;
	if(m.nv >= MAXV)
		return 0;	# original would overflow its static array
	i = m.nv++;
	m.vx[i] = x;
	m.vy[i] = y;
	m.vz[i] = z;
	return i;
}

addtri(c, n0, n1, n2: int)
{
	m := mesh;
	if(m.nt >= MAXT)
		return;
	i := m.nt++;
	m.tc[i] = c;
	m.t0[i] = n0;
	m.t1[i] = n1;
	m.t2[i] = n2;
}

genball()
{
	newmesh();
	# BDCorrect on a copy: (n+1)/2 halving
	m := (bd_lon + 1) / 2;
	n := (bd_lat + 1) / 2;
	c := picked[0];
	r := bd_rad;
	if(n < 1 || m < 1)
		return;
	da1 := 2.0 * Math->Pi / real n / 4.0;
	da2 := 2.0 * Math->Pi / real m / 2.0;
	for(j := -n; j < n; j++){
		r1 := r * math->cos(real j * da1);
		r2 := r * math->cos(real (j+1) * da1);
		z1 := int (r * math->sin(real j * da1));
		z2 := int (r * math->sin(real (j+1) * da1));
		for(i := 0; i < m; i++){
			p1 := addvb(int (r1*math->cos(real(2*i+j)*da2)), int (r1*math->sin(real(2*i+j)*da2)), z1);
			p2 := addvb(int (r1*math->cos(real(2*i+2+j)*da2)), int (r1*math->sin(real(2*i+2+j)*da2)), z1);
			p3 := addvb(int (r2*math->cos(real(2*i+1+j)*da2)), int (r2*math->sin(real(2*i+1+j)*da2)), z2);
			p4 := addvb(int (r2*math->cos(real(2*i+3+j)*da2)), int (r2*math->sin(real(2*i+3+j)*da2)), z2);
			addtri(c, p1, p2, p3);
			addtri(c, p3, p2, p4);
		}
	}
}

man_yoff := 0.0;

# ManGen AddVertex: no dedup; negate and drop to stand on the baseline
addvm(x, y, z: int): int
{
	m := mesh;
	if(m.nv >= MAXV)
		return 0;
	i := m.nv++;
	m.vx[i] = -x;
	m.vy[i] = int (real (-y) - man_yoff);
	m.vz[i] = -z;
	return i;
}

# ManGen AddTri stores nums[0]=n1, nums[1]=n0, nums[2]=n2 (winding flip)
addtm(c, n0, n1, n2: int)
{
	addtri(c, n1, n0, n2);
}

# apply Rz(az) then Ry(ay) then Rx(ax), degrees, to an integer vector;
# Mat4x4RotZ/Y/X pre-multiply (each "applied after"), so v' = Rx.Ry.Rz.v
rotv(az, ay, ax: real, x, y, z: int): (int, int, int)
{
	xr := real x;
	yr := real y;
	zr := real z;
	a := az * Math->Pi / 180.0;
	c := math->cos(a);
	s := math->sin(a);
	(xr, yr) = (c*xr - s*yr, s*xr + c*yr);
	a = ay * Math->Pi / 180.0;
	c = math->cos(a);
	s = math->sin(a);
	(xr, zr) = (c*xr + s*zr, -s*xr + c*zr);
	a = ax * Math->Pi / 180.0;
	c = math->cos(a);
	s = math->sin(a);
	(yr, zr) = (c*yr - s*zr, s*yr + c*zr);
	return (int xr, int yr, int zr);
}

# ManGen AddBox: half-extents rounded to ints BEFORE rotation, like the
# original's I64 locals; returns the chained joint origin
addbox(c: int, x1f, y1f, z1f, w, h, d, h2, h3, az, ay, ax: real): (int, int, int)
{
	x1 := int x1f;
	y1 := int y1f;
	z1 := int z1f;
	(wx, wy, wz) := rotv(az, ay, ax, int (w/2.0), 0, 0);
	(hx, hy, hz) := rotv(az, ay, ax, 0, int h, 0);
	(h2x, h2y, h2z) := rotv(az, ay, ax, 0, int h2, 0);
	(h3x, h3y, h3z) := rotv(az, ay, ax, 0, int h3, 0);
	(dx, dy, dz) := rotv(az, ay, ax, 0, 0, int (d/2.0));

	p1a := addvm(x1+dx-wx+h2x, y1+dy-wy+h2y, z1+dz-wz+h2z);
	p2a := addvm(x1+dx+wx+h2x, y1+dy+wy+h2y, z1+dz+wz+h2z);
	p3a := addvm(x1+dx+hx-wx, y1+dy+hy-wy, z1+dz+hz-wz);
	p4a := addvm(x1+dx+hx+wx, y1+dy+hy+wy, z1+dz+hz+wz);
	addtm(c, p1a, p2a, p3a);
	addtm(c, p4a, p3a, p2a);

	p1b := addvm(x1-dx-wx+h2x, y1-dy-wy+h2y, z1-dz-wz+h2z);
	p2b := addvm(x1-dx+wx+h2x, y1-dy+wy+h2y, z1-dz+wz+h2z);
	p3b := addvm(x1-dx+hx-wx, y1-dy+hy-wy, z1-dz+hz-wz);
	p4b := addvm(x1-dx+hx+wx, y1-dy+hy+wy, z1-dz+hz+wz);
	addtm(c, p1b, p2b, p3b);
	addtm(c, p4b, p3b, p2b);

	addtm(c, p1a, p2a, p1b);
	addtm(c, p2b, p1b, p2a);
	addtm(c, p3a, p4a, p3b);
	addtm(c, p4b, p3b, p4a);
	addtm(c, p1a, p3a, p1b);
	addtm(c, p3b, p1b, p3a);
	addtm(c, p2a, p4a, p2b);
	addtm(c, p4b, p2b, p4a);

	return (x1+hx-h3x, y1+hy-h3y, z1+hz-h3z);
}

genman()
{
	newmesh();
	head_rad := mdv[0];
	torso_len := mdv[1];
	arm_len := mdv[2];
	hand_len := mdv[3];
	leg_len := mdv[4];
	foot_len := mdv[5];
	torso_width := mdv[6];
	torso_depth := mdv[7];
	arm_rad := mdv[8];
	hand_rad := mdv[9];
	leg_rad := mdv[10];
	foot_rad := mdv[11];
	rsh1 := mdv[12];
	lsh1 := mdv[13];
	rhip1 := mdv[14];
	lhip1 := mdv[15];
	rsh2 := mdv[16];
	lsh2 := mdv[17];
	rhip2 := mdv[18];
	lhip2 := mdv[19];
	relb := mdv[20];
	lelb := mdv[21];
	rknee := mdv[22];
	lknee := mdv[23];
	rwr := mdv[24];
	lwr := mdv[25];
	rank := mdv[26];
	lank := mdv[27];

	# MDCorrect, in the original's exact order
	rank = -rank;
	lank = -lank;
	rknee = -rknee;
	lknee = -lknee;
	rhip2 = -rhip2;
	rsh2 = -rsh2;
	rank += 90.0;
	lank += 90.0;
	foot_len -= leg_rad;
	relb += rsh1;
	lelb += lsh1;
	rknee += rhip1;
	lknee += lhip1;
	rwr += relb;
	lwr += lelb;
	rank += rknee;
	lank += lknee;

	man_yoff = leg_len + foot_rad*2.0;

	c1 := picked[0];	# Shirt
	c2 := picked[1];	# Pants
	c3 := picked[2];	# Skin
	c4 := picked[3];	# Shoes
	x, y, z: int;

	# Head
	(x, y, z) = addbox(c3, 0.0, torso_len+head_rad*2.0, 0.0,
		head_rad*2.0, -head_rad*2.0, head_rad*2.0, 0.0, 0.0, 0.0, 0.0, 0.0);

	# Torso
	(x, y, z) = addbox(c1, 0.0, torso_len, 0.0,
		torso_width, -torso_len, torso_depth, 0.0, 0.0, 0.0, 0.0, 0.0);

	# Right Arm
	(x, y, z) = addbox(c1, -torso_width/2.0-arm_rad, torso_len-arm_rad, 0.0,
		arm_rad*2.0, -arm_len/2.0, arm_rad*2.0, arm_rad, 0.0,
		rsh2, 0.0, rsh1);
	(x, y, z) = addbox(c3, real x, real y, real z,
		arm_rad*2.0, -arm_len/2.0, arm_rad*2.0, 0.0, 0.0,
		rsh2, 0.0, relb);
	(x, y, z) = addbox(c3, real x, real y, real z,
		arm_rad*2.0, -hand_len, hand_rad*2.0, 0.0, 0.0,
		rsh2, 0.0, rwr);

	# Left Arm
	(x, y, z) = addbox(c1, torso_width/2.0+arm_rad, torso_len-arm_rad, 0.0,
		arm_rad*2.0, -arm_len/2.0, arm_rad*2.0, arm_rad, 0.0,
		lsh2, 0.0, lsh1);
	(x, y, z) = addbox(c3, real x, real y, real z,
		arm_rad*2.0, -arm_len/2.0, arm_rad*2.0, 0.0, 0.0,
		lsh2, 0.0, lelb);
	(x, y, z) = addbox(c3, real x, real y, real z,
		arm_rad*2.0, -hand_len, hand_rad*2.0, 0.0, 0.0,
		lsh2, 0.0, lwr);

	# Right Leg
	(x, y, z) = addbox(c2, -torso_width/2.0+leg_rad, 0.0, 0.0,
		leg_rad*2.0, -leg_len/2.0, leg_rad*2.0, 0.0, 0.0,
		rhip2, 0.0, rhip1);
	(x, y, z) = addbox(c3, real x, real y, real z,
		leg_rad*2.0, -leg_len/2.0, leg_rad*2.0, 0.0, foot_rad,
		rhip2, 0.0, rknee);
	(x, y, z) = addbox(c4, real x, real y, real z,
		leg_rad*2.0, -foot_len, foot_rad*2.0, leg_rad, 0.0,
		rhip2, 0.0, rank);

	# Left Leg
	(x, y, z) = addbox(c2, torso_width/2.0-leg_rad, 0.0, 0.0,
		leg_rad*2.0, -leg_len/2.0, leg_rad*2.0, 0.0, 0.0,
		lhip2, 0.0, lhip1);
	(x, y, z) = addbox(c3, real x, real y, real z,
		leg_rad*2.0, -leg_len/2.0, leg_rad*2.0, 0.0, foot_rad,
		lhip2, 0.0, lknee);
	(x, y, z) = addbox(c4, real x, real y, real z,
		leg_rad*2.0, -foot_len, foot_rad*2.0, leg_rad, 0.0,
		lhip2, 0.0, lank);
}

generate()
{
	if(gmode == T_BALL)
		genball();
	else
		genman();
	err := savesprite();
	if(err == nil)
		savedmsg = "CSprite written to grmodels.csprite";
	else
		savedmsg = "CSprite save failed: " + err;
	yaw = 0.0;
	pitch = 0.0;
	zoom = 1.0;
	drag = 0;
	state = SRESULT;
	redraw();
}

# Ball2CSprite/Man2CSprite byte layout: SPT_MESH, I32 vertex_cnt, I32 tri_cnt,
# vertex_cnt CD3I32 (x,y,z I32), tri_cnt CMeshTri (color,nums[3] I32), SPT_END
savesprite(): string
{
	m := mesh;
	buf := array[9 + m.nv*12 + m.nt*16 + 1] of byte;
	buf[0] = byte SPTMESH;
	o := p32(buf, 1, m.nv);
	o = p32(buf, o, m.nt);
	for(i := 0; i < m.nv; i++){
		o = p32(buf, o, m.vx[i]);
		o = p32(buf, o, m.vy[i]);
		o = p32(buf, o, m.vz[i]);
	}
	for(i = 0; i < m.nt; i++){
		o = p32(buf, o, m.tc[i]);
		o = p32(buf, o, m.t0[i]);
		o = p32(buf, o, m.t1[i]);
		o = p32(buf, o, m.t2[i]);
	}
	buf[o++] = byte 0;	# SPT_END
	fd := sys->create("grmodels.csprite", Sys->OWRITE, 8r664);
	if(fd == nil)
		return sys->sprint("%r");
	if(sys->write(fd, buf, len buf) != len buf)
		return sys->sprint("%r");
	return nil;
}

p32(buf: array of byte, o, v: int): int
{
	buf[o] = byte v;
	buf[o+1] = byte (v>>8);
	buf[o+2] = byte (v>>16);
	buf[o+3] = byte (v>>24);
	return o + 4;
}

# ---------- drawing ----------

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	case state {
	SMENU =>	drawmenu(img);
	SFORM =>	drawform(img);
	SCOLOR =>	drawcolor(img);
	SRESULT =>	drawresult(img);
	}
	img.flush(Draw->Flushnow);
}

txtat(img: ref Image, p: Point, s: string, colr: ref Image)
{
	img.text(p, colr, Point(0, 0), tosfont, s);
}

frame(img: ref Image, r: Rect, colr: ref Image)
{
	img.draw(Rect((r.min.x, r.min.y), (r.max.x, r.min.y+1)), colr, nil, Point(0,0));
	img.draw(Rect((r.min.x, r.max.y-1), (r.max.x, r.max.y)), colr, nil, Point(0,0));
	img.draw(Rect((r.min.x, r.min.y), (r.min.x+1, r.max.y)), colr, nil, Point(0,0));
	img.draw(Rect((r.max.x-1, r.min.y), (r.max.x, r.max.y)), colr, nil, Point(0,0));
}

button(img: ref Image, p: Point, label: string, sel: int): Rect
{
	r := Rect(p, p.add((len label * 8 + 16, 16)));
	img.draw(r, ink[7], nil, Point(0,0));
	frame(img, r, ink[0]);
	# drop shadow, TempleOS button relief
	img.draw(Rect((r.min.x+2, r.max.y), (r.max.x+2, r.max.y+2)), ink[8], nil, Point(0,0));
	img.draw(Rect((r.max.x, r.min.y+2), (r.max.x+2, r.max.y+2)), ink[8], nil, Point(0,0));
	txtat(img, p.add((8, 4)), label, ink[0]);
	if(sel)
		frame(img, r.inset(1), ink[4]);
	return r;
}

drawmenu(img: ref Image)
{
	img.draw(img.r, ink[15], nil, Point(0,0));
	o := img.r.min;
	# the Models() DolDoc page: white page, default blue text, LM=4 buttons
	txtat(img, o.add((8, 8)), "Make a CSprite model.Then, cut-and-Paste it.", ink[1]);
	manr = button(img, o.add((32, 48)), "Man", menusel == 0);
	ballr = button(img, o.add((32, 96)), "Ball", menusel == 1);
	txtat(img, o.add((8, img.r.dy() - 16)),
		"Enter or click chooses; Esc quits.", ink[8]);
}

drawform(img: ref Image)
{
	img.draw(img.r, ink[15], nil, Point(0,0));
	o := img.r.min;
	for(i := 0; i < len fields; i++){
		row := 1 + i;
		if(gmode == T_MAN && i >= 12)
			row++;		# the blank line after Foot Radius
		y := o.y + row*8;
		x := o.x + 8;
		txtat(img, Point(x, y), fields[i].label, ink[1]);
		vx0 := x + len fields[i].label * 8;
		r := Rect((vx0, y), (vx0 + fields[i].vw*8, y+8));
		fields[i].r = r;
		bg := ink[7];
		fg := ink[0];
		if(i == fsel){
			bg = ink[1];
			fg = ink[15];
		}
		img.draw(r, bg, nil, Point(0,0));
		s := fields[i].val;
		dx := 0;
		if(len s < fields[i].vw)
			dx = (fields[i].vw - len s) * 8;
		txtat(img, Point(vx0 + dx, y), s, fg);
	}
	txtat(img, o.add((8, img.r.dy() - 16)),
		"Esc=OK  Del=abort  Enter=next  ctl-u=clear", ink[8]);
}

pline(img: ref Image, x, y: int, s: string, colr: ref Image): int
{
	txtat(img, Point(x, y), s, colr);
	return y + 8;
}

pentry(img: ref Image, x, y, ci, v, idx: int)
{
	s := sys->sprint("__%-19s__", colornames[ci]);
	r := Rect((x, y), (x + 23*8, y+8));
	img.draw(r, ink[ci], nil, Point(0,0));
	txtat(img, Point(x, y), s, ink[0]);
	pents_r[idx] = r;
	pents_v[idx] = v;
	if(idx == picksel){
		frame(img, Rect((r.min.x-1, r.min.y-1), (r.max.x+1, r.max.y+1)), ink[0]);
		frame(img, r, ink[15]);
	}
}

drawcolor(img: ref Image)
{
	img.draw(img.r, ink[15], nil, Point(0,0));
	o := img.r.min;
	pents_r = array[48] of Rect;
	pents_v = array[48] of int;
	npents = 48;

	hdr := pickhdrs[pickidx];
	pw := 47*8 + 16;
	nrows := 35;
	if(hdr != nil)
		nrows++;
	ph := nrows*8 + 16;
	px := o.x + (img.r.dx() - pw) / 2;
	py := o.y + (img.r.dy() - ph) / 2;
	panel := Rect((px, py), (px+pw, py+ph));
	img.draw(Rect(panel.min.add((4,4)), panel.max.add((4,4))), ink[8], nil, Point(0,0));
	img.draw(panel, ink[15], nil, Point(0,0));
	frame(img, panel, ink[0]);

	x := px + 8;
	y := py + 8;
	if(hdr != nil){
		# $$BK,1$$ blinking header
		if(blink % 2 == 0)
			txtat(img, Point(x, y), hdr, ink[0]);
		y += 8;
	}
	y += 8;		# leading blank line
	y = pline(img, x, y, "Single-Sided means front and back different.", ink[0]);
	y = pline(img, x, y, "Double-Sided means front and back same.", ink[0]);
	y += 8;
	y = pline(img, x, y, "Half-Range means 0to[0,7]", ink[0]);
	y = pline(img, x, y, "[8,15]-8to[8,15]", ink[0]);
	y = pline(img, x, y, "Full-Range means 0to[0,7]to[0,7]+8", ink[0]);
	y += 8;
	y = pline(img, x, y, "Single-Sided Full-Range Double-Sided Full-Range", ink[13]);
	idx := 0;
	for(i := 0; i < 8; i++){
		pentry(img, x, y, i, i, idx++);
		pentry(img, x + 24*8, y, i, ROPFTWOSIDED+i, idx++);
		y += 8;
	}
	y += 8;
	y = pline(img, x, y, "Single-Sided Half-Range Double-Sided Half-Range", ink[13]);
	for(i = 0; i < 16; i++){
		pentry(img, x, y, i, ROPFHALF+i, idx++);
		pentry(img, x + 24*8, y, i, ROPFTWOSIDED+ROPFHALF+i, idx++);
		y += 8;
	}
}

drawresult(img: ref Image)
{
	img.draw(img.r, ink[15], nil, Point(0,0));
	o := img.r.min;
	area := Rect((o.x, o.y + 16), (o.x + img.r.dx(), o.y + img.r.dy() - 40));
	drawmesh(img, area);
	by := o.y + img.r.dy() - 32;
	if(gmode == T_BALL)
		txtat(img, Point(o.x+8, by-8), sys->sprint("Vertices:%d", mesh.nv), ink[1]);
	txtat(img, Point(o.x+8, by), "Do another (Y/N)?", ink[1]);
	txtat(img, Point(o.x+8, by+8), savedmsg + "; drag rotates, +/- zooms", ink[8]);
}

# DCLighting transliteration: normal from the tri's (transformed) vertices,
# dotted with the default light source (1,1,1)/sqrt(3), then probability
# dither BLACK..color (i<65536) or color..color^8 (i>=65536), with the
# TWO_SIDED (abs, doubled) and HALF_RANGE (halved; 8..15 shade c-8..c) flags
trishade(c: int, x0, y0, z0, x1, y1, z1, x2, y2, z2: real): ref Image
{
	v1x := x0 - x1;
	v1y := y0 - y1;
	v1z := z0 - z1;
	v2x := x2 - x1;
	v2y := y2 - y1;
	v2z := z2 - z1;
	nx := v1y*v2z - v1z*v2y;
	ny := v1z*v2x - v1x*v2z;
	nz := v1x*v2y - v1y*v2x;
	d := math->sqrt(nx*nx + ny*ny + nz*nz);
	dot := 0.0;
	if(d > 0.0)
		dot = (nx + ny + nz) * 0.5773502691896258 / d;
	col := c & 15;
	t: real;
	if(c & ROPFTWOSIDED){
		t = dot;
		if(t < 0.0)
			t = -t;
		t *= 2.0;
	}else
		t = dot + 1.0;
	if(c & ROPFHALF){
		t /= 2.0;
		if(col >= 8){
			col -= 8;
			t += 1.0;
		}
	}
	if(t < 1.0)
		return tile(0, col, int (t*16.0));
	return tile(col, col ^ 8, int ((t-1.0)*16.0));
}

# 4x4 Bayer ordered-dither tile mixing palette colors a and b;
# lvl 0..16 = number of b pixels per 16 (TempleOS dithers per-pixel randomly;
# an ordered tile gives the same mix, stable across frames)
tile(a, b, lvl: int): ref Image
{
	if(lvl < 0)
		lvl = 0;
	if(lvl > 16)
		lvl = 16;
	if(lvl == 0 || a == b)
		return ink[a];
	if(lvl == 16)
		return ink[b];
	key := (a*16 + b)*17 + lvl;
	if(tiles[key] != nil)
		return tiles[key];
	t := disp.newimage(Rect((0,0), (4,4)), Draw->RGB24, 1, Draw->Black);
	if(t == nil)
		return ink[a];
	data := array[4*4*3] of byte;
	for(i := 0; i < 16; i++){
		v := palette[a];
		if(bayer4[i] < lvl)
			v = palette[b];
		data[i*3] = byte (v>>8);	# blue
		data[i*3+1] = byte (v>>16);	# green
		data[i*3+2] = byte (v>>24);	# red
	}
	t.writepixels(Rect((0,0), (4,4)), data);
	tiles[key] = t;
	return t;
}

drawmesh(img: ref Image, area: Rect)
{
	m := mesh;
	if(m == nil || m.nt == 0 || m.nv == 0)
		return;
	minx := m.vx[0]; maxx := m.vx[0];
	miny := m.vy[0]; maxy := m.vy[0];
	minz := m.vz[0]; maxz := m.vz[0];
	for(i := 1; i < m.nv; i++){
		if(m.vx[i] < minx) minx = m.vx[i];
		if(m.vx[i] > maxx) maxx = m.vx[i];
		if(m.vy[i] < miny) miny = m.vy[i];
		if(m.vy[i] > maxy) maxy = m.vy[i];
		if(m.vz[i] < minz) minz = m.vz[i];
		if(m.vz[i] > maxz) maxz = m.vz[i];
	}
	cx := real (minx+maxx) / 2.0;
	cy := real (miny+maxy) / 2.0;
	cz := real (minz+maxz) / 2.0;
	sy := math->sin(yaw);
	cyw := math->cos(yaw);
	sp := math->sin(pitch);
	cp := math->cos(pitch);
	vcx := real (area.min.x + area.max.x) / 2.0;
	vcy := real (area.min.y + area.max.y) / 2.0;

	tx := array[m.nv] of real;
	ty := array[m.nv] of real;
	tz := array[m.nv] of real;
	for(i = 0; i < m.nv; i++){
		dx := real m.vx[i] - cx;
		dy := real m.vy[i] - cy;
		dz := real m.vz[i] - cz;
		x1 := dx*cyw + dz*sy;
		z1 := -dx*sy + dz*cyw;
		y2 := dy*cp - z1*sp;
		z2 := dy*sp + z1*cp;
		tx[i] = vcx + zoom*x1;
		ty[i] = vcy + zoom*y2;
		tz[i] = zoom*z2;
	}

	# painter's algorithm stands in for the TempleOS depth buffer:
	# larger z is deeper into the screen; draw far-to-near
	fz := array[m.nt] of real;
	order := array[m.nt] of int;
	for(i = 0; i < m.nt; i++){
		order[i] = i;
		fz[i] = (tz[m.t0[i]] + tz[m.t1[i]] + tz[m.t2[i]]) / 3.0;
	}
	for(i = 0; i < m.nt; i++){
		for(j := i+1; j < m.nt; j++){
			if(fz[order[j]] > fz[order[i]]){
				tmp := order[i];
				order[i] = order[j];
				order[j] = tmp;
			}
		}
	}

	for(ii := 0; ii < m.nt; ii++){
		i = order[ii];
		a := m.t0[i];
		b := m.t1[i];
		c := m.t2[i];
		colimg := trishade(m.tc[i],
			tx[a], ty[a], tz[a],
			tx[b], ty[b], tz[b],
			tx[c], ty[c], tz[c]);
		fill_tri(img, int tx[a], int ty[a], int tx[b], int ty[b],
			int tx[c], int ty[c], colimg);
	}
}

fill_tri(img: ref Image, x0, y0, x1, y1, x2, y2: int, col: ref Image)
{
	# scanline fill via edge intersections
	miny := y0;
	if(y1 < miny) miny = y1;
	if(y2 < miny) miny = y2;
	maxy := y0;
	if(y1 > maxy) maxy = y1;
	if(y2 > maxy) maxy = y2;
	for(y := miny; y <= maxy; y++){
		xs: list of int;
		xs = scan_edge(x0, y0, x1, y1, y, xs);
		xs = scan_edge(x1, y1, x2, y2, y, xs);
		xs = scan_edge(x2, y2, x0, y0, y, xs);
		if(xs == nil)
			continue;
		xa := 1000000;
		xb := -1000000;
		for(xl := xs; xl != nil; xl = tl xl){
			x := hd xl;
			if(x < xa) xa = x;
			if(x > xb) xb = x;
		}
		if(xa <= xb)
			img.draw(Rect((xa, y), (xb+1, y+1)), col, nil, Point(xa, y));
	}
}

scan_edge(x0, y0, x1, y1, y: int, xs: list of int): list of int
{
	if(y0 == y1)
		return xs;
	if((y < y0 && y < y1) || (y > y0 && y > y1))
		return xs;
	t := real (y - y0) / real (y1 - y0);
	x := int (real x0 + t * real (x1 - x0));
	return x :: xs;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
