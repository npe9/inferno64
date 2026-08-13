implement Castlefrankenstein;

# TempleOS Demo/Games/CastleFrankenstein.HC — maze shooter
# FPS view via math/draw3d; LOS still gates combat + visible walls
# GAP: no TempleOS Sprite3 map art
# up/down move  left/right turn  space=fire  Enter restart  q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import draw3d;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

include "scorestore.m";
	scorestore: Scorestore;

Castlefrankenstein: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MW: con 36;
MH: con 32;
CELL: con 16;
MONS: con 10;
VIEWW: con 24;
VIEWH: con 18;
SCRN_SCALE: con 512;
WALL_H: con 1.0;
PI: con 3.141592653589793;
NEAR: con 0.05;
CAMERA_EPS: con 0.001;
FOCAL_OFFSET: con 1.0/3.0;
EYE_H: con 125.0/512.0;
BODY_RADIUS: con 0.08;

T_EMPTY: con 0;
T_FLOOR: con 1;
T_PLANT: con 2;
T_BLOCK: con 3;
T_STATUE: con 4;

# The first DolDoc bin in CastleFrankenstein.HC is the hand-drawn map.  These
# rows are its 4-pixel samples, matching Sprite2DC/GrPeek in TempleOS.  The
# outer one-cell border is added by gen_map.
castlemap := array[] of {
	"....sfsfsff.......................",
	"....fffffff.......................",
	"....fffffff.......................",
	"....ffppfff.......................",
	"....ffppfff.....b.................",
	"....fffffff.....b.................",
	"....fffffff.....b.................",
	".......f........b.................",
	".......f........b.................",
	".......f........b.................",
	".......f..sfsfsfbfpff.....ffffffff",
	".sfff..f..ffffffbfffp.....ffffffff",
	".ffff..f..ffffffbffff.....ffffffff",
	".sffffffffffffffffffffffffffffffff",
	".ffff.....ffffffbffff.....ffffffff",
	".sfff.....ffffffbfffp.....fffppfff",
	"..........ffffffbffff.....fffppfff",
	"..........ffffffbfpfp.....ffffffff",
	"..........f.....b..............fff",
	"..........f.....b..............fff",
	"..........f.....b..............fff",
	"..........f.....b...............f.",
	".......ffffffff.b.....ffffff....f.",
	".......ffffffpf.b.sf..ffffff....f.",
	".......ffffffff.b.ff..ffffff....f.",
	"fffffffffffffff.b.fffffffffffffff.",
	".......ffffffff.b.ff..ffffff......",
	".......ffffffpf.b.sf..ffffff......",
	".......ffffffff.b.....ffffff......",
	"................b................."
};

# Painter sort keys for billboards
Bill: adt {
	x, y, z, dist: real;
	kind: int;	# 0 plant 1 mon 2 muzzle
};

Tri: adt { colour, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
blue, hudbg, floorc, plantc, monsc, fog, red, green, cyan, yellow: ref Image;
have_tone := 0;
blink_on := 0;
palette: array of ref Image;
meshes: array of ref Mesh;
interpmesh: ref Mesh;

map: array of array of int;
visible: array of array of int;
man_x, man_y: real;
man_a: real;
cam_x, cam_y, cam_a: real;
mon_x, mon_y: array of real;
mon_dead: array of int;
monsters_left := 0;
fire_t0 := 0;
t0, tf: int;
best_score: real;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	# Prefer protocol-backed draw3ddev; fall back to software draw3d.dis.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "castlefrankenstein: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	draw3d->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS CastleFrankenstein", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	blue = d.color(Draw->Blue);
	hudbg = d.color(int 16r101018FF);
	floorc = d.color(int 16r666666FF);
	plantc = d.color(int 16r886644FF);
	monsc = d.color(Draw->Red);
	fog = d.color(int 16r111111FF);
	red = d.color(Draw->Red);
	green = d.color(Draw->Green);
	cyan = d.color(Draw->Cyan);
	yellow = d.color(Draw->Yellow);
	# Exact TempleOS gr_palette_std.  Draw's named colours use Inferno's
	# brighter display palette and are not interchangeable with these indices.
	palette = array[] of {
		d.color(int 16r000000FF), d.color(int 16r0000AAFF),
		d.color(int 16r00AA00FF), d.color(int 16r00AAAAFF),
		d.color(int 16rAA0000FF), d.color(int 16rAA00AAFF),
		d.color(int 16rAA5500FF), d.color(int 16rAAAAAAFF),
		d.color(int 16r555555FF), d.color(int 16r5555FFFF),
		d.color(int 16r55FF55FF), d.color(int 16r55FFFFFF),
		d.color(int 16rFF5555FF), d.color(int 16rFF55FFFF),
		d.color(int 16rFFFF55FF), d.color(int 16rFFFFFFFF)
	};
	meshes = array[7] of ref Mesh;
	for(mi := 2; mi <= 6; mi++)
		meshes[mi] = loadmesh(sys->sprint("/icons/temple/castle_%d.mesh", mi));
	if(meshes[3] != nil && meshes[4] != nil &&
	   len meshes[3].v == len meshes[4].v && len meshes[3].f == len meshes[4].f)
		interpmesh = ref Mesh(array[len meshes[3].v] of Vector, meshes[3].f);
	best_score = 9999.0;
	if(scorestore != nil)
		best_score = scorestore->loadreal("castlefrankenstein", best_score);
	game_init();
	if(have_tone)
		spawn castle_song();
	win.reshape(Rect((0, 0), (VIEWW*CELL, VIEWH*CELL+20)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	mtick := chan of int;
	spawn mon_timer(mtick, 20);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		' ' =>
			do_fire();
		Keyboard->Left or 'a' or 'A' =>
			man_a += PI/32.0;
		Keyboard->Right or 'd' or 'D' =>
			man_a -= PI/32.0;
		Keyboard->Up or 'w' or 'W' =>
			try_move(man_a, 0.5);
		Keyboard->Down or 's' or 'S' =>
			try_move(man_a + PI, 0.5);
		}
	<-mtick =>
		if(!tf)
			move_monsters();
	<-ticks =>
		blink_on = (sys->millisec() / 250) % 2;
		update_camera();
		redraw();
	}
}

game_init()
{
	map = array[MH] of { * => array[MW] of { * => T_EMPTY } };
	visible = array[MH] of { * => array[MW] of { * => 0 } };
	gen_map();
	(man_x, man_y) = find_start();
	man_a = 0.0;
	cam_x = man_x;
	cam_y = man_y;
	cam_a = man_a;
	mon_x = array[MONS] of real;
	mon_y = array[MONS] of real;
	mon_dead = array[MONS] of int;
	for(i := 0; i < MONS; i++){
		mon_dead[i] = 0;
		for(;;){
			x := 1.0 + real rn((MW-2)*512)/512.0;
			y := 1.0 + real rn((MH-2)*512)/512.0;
			if(map[cell(y)][cell(x)] != T_EMPTY){
				mon_x[i] = x;
				mon_y[i] = y;
				break;
			}
		}
	}
	monsters_left = MONS;
	tf = 0;
	t0 = sys->millisec();
	fire_t0 = 0;
}

gen_map()
{
	for(my := 0; my < MH; my++)
		for(mx := 0; mx < MW; mx++)
			map[my][mx] = T_EMPTY;
	for(ry := 0; ry < len castlemap; ry++){
		s := castlemap[ry];
		# The rows are already in the source sprite's reversed screen order.
		my = ry + 1;
		for(rx := 0; rx < len s; rx++)
			case s[rx] {
			'f' => map[my][rx+1] = T_FLOOR;
			'p' => map[my][rx+1] = T_PLANT;
			'b' => map[my][rx+1] = T_BLOCK;
			's' => map[my][rx+1] = T_STATUE;
			}
	}
}

find_start(): (real, real)
{
	# MAN_START_X=0 and MAN_START_Y=4.5 in CastleFrankenstein.HC.
	return (1.0, real(MH-1)-4.5);
}

tile_ok(tx, ty: int): int
{
	if(tx < 0 || tx >= MW || ty < 0 || ty >= MH)
		return 0;
	if(map[ty][tx] != T_FLOOR && map[ty][tx] != T_PLANT)
		return 0;
	return 1;
}

position_ok(x, y: real): int
{
	if(!tile_ok(cell(x), cell(y)))
		return 0;
	# Circle-versus-solid-cell clearance keeps the eye out of paper-thin walls.
	for(ty := cell(y-BODY_RADIUS); ty <= cell(y+BODY_RADIUS); ty++)
		for(tx := cell(x-BODY_RADIUS); tx <= cell(x+BODY_RADIUS); tx++){
			if(tile_ok(tx, ty))
				continue;
			qx := x;
			if(qx < real tx) qx = real tx;
			if(qx > real(tx+1)) qx = real(tx+1);
			qy := y;
			if(qy < real ty) qy = real ty;
			if(qy > real(ty+1)) qy = real(ty+1);
			dx := x-qx;
			dy := y-qy;
			if(dx*dx+dy*dy < BODY_RADIUS*BODY_RADIUS)
				return 0;
		}
	return 1;
}

try_move(a, step: real)
{
	# TempleOS starts with a half-cell move, then halves a blocked step until
	# the largest legal sub-step fits.  This lets the player approach a wall
	# closely instead of stopping a full half-cell away from it.
	ca := math->cos(a);
	sa := math->sin(a);
	for(; step >= 1.0/512.0; step /= 2.0){
		nx := man_x + step * ca;
		ny := man_y - step * sa;
		if(position_ok(nx, ny)){
			man_x = nx;
			man_y = ny;
			break;
		}
		# Resolve axes separately so a blocked diagonal glides along the wall.
		if(position_ok(nx, man_y)){
			man_x = nx;
			break;
		}
		if(position_ok(man_x, ny)){
			man_y = ny;
			break;
		}
	}
}

update_camera()
{
	# The HolyC renderer and collision state share one exact viewpoint.
	cam_x = man_x;
	cam_y = man_y;
	cam_a = man_a;
}

do_fire()
{
	fire_t0 = sys->millisec();
	if(have_tone)
		tone->beep(53, 80);
	ca := math->cos(cam_a);
	sa := -math->sin(cam_a);
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		dx := mon_x[i] - man_x;
		dy := mon_y[i] - man_y;
		d := math->sqrt(dx*dx + dy*dy);
		if(d < 0.5)
			continue;
		if(!los(cell(man_x), cell(man_y), cell(mon_x[i]), cell(mon_y[i])))
			continue;
		dx /= d;
		dy /= d;
		if(dx*ca + dy*sa > 0.995){
			mon_dead[i] = 1;
			monsters_left--;
			if(!monsters_left){
				tf = sys->millisec();
				elapsed := real(tf - t0) / 1000.0;
				if(elapsed < best_score)
					best_score = elapsed;
				if(scorestore != nil)
					scorestore->savereal("castlefrankenstein", best_score);
			}
		}
	}
}

move_monsters()
{
	t := real sys->millisec()/1000.0;
	dd := 0.25*math->sin(t/2.0);
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		nx := mon_x[i];
		ny := mon_y[i];
		if(i & 1)
			nx += dd;
		else
			ny += dd;
		if(cell(nx) >= 0 && cell(nx) < MW && cell(ny) >= 0 && cell(ny) < MH &&
			map[cell(ny)][cell(nx)] != T_EMPTY){
			tx := cell(nx);
			ty := cell(ny);
			fx := nx-real tx;
			fy := ny-real ty;
			if((map[ty][tx+1] == T_EMPTY && fx > 0.5) ||
			   (map[ty][tx-1] == T_EMPTY && fx < 0.5))
				nx = real tx+0.5;
			if((map[ty+1][tx] == T_EMPTY && fy > 0.5) ||
			   (map[ty-1][tx] == T_EMPTY && fy < 0.5))
				ny = real ty+0.5;
			mon_x[i] = nx;
			mon_y[i] = ny;
		}
	}
}

los(x1, y1, x2, y2: int): int
{
	dx := absi(x2 - x1);
	dy := absi(y2 - y1);
	sx := 1;
	if(x1 > x2) sx = -1;
	sy := 1;
	if(y1 > y2) sy = -1;
	err := dx - dy;
	x := x1;
	y := y1;
	for(;;){
		if(x == x2 && y == y2)
			return 1;
		if(map[y][x] == T_EMPTY && !(x == x1 && y == y1))
			return 0;
		e2 := 2 * err;
		if(e2 > -dy){
			err -= dy;
			x += sx;
		}
		if(e2 < dx){
			err += dx;
			y += sy;
		}
	}
}

# World: x = map-x, y = height, z = map-y. Camera follows the player smoothly.
cf_xform(v: Vector): Vector
{
	tx := v.x - cam_x;
	ty := v.y - EYE_H;
	tz := v.z - cam_y;
	ca := math->cos(cam_a);
	sa := math->sin(cam_a);
	rx := tx * sa + tz * ca;
	rz := tx * ca - tz * sa;
	# Polygons are clipped to NEAR before reaching this transform.  Use a much
	# smaller guard here so rounding at the clip plane cannot reject a complete
	# polygon on alternating frames.
	denom := rz + FOCAL_OFFSET;
	if(denom < CAMERA_EPS)
		return Vector(0.0, 0.0, 1.0);
	sx := (real SCRN_SCALE / 2.0) * rx / denom;
	# Draw screen Y grows downward.  World Y grows upward, so perspective Y
	# must be inverted here (the previous sign put the floor above the camera).
	sy := -(real SCRN_SCALE / 2.0) * ty / denom;
	# CFTransform uses zz only for perspective division; its transformed z
	# remains the camera-forward coordinate used by the depth buffer.
	return Vector(sx / d3c.mx, sy / d3c.my, -rz);
}

setup3d(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);
	draw3d->clearz(d3c);
	draw3d->setzclip(d3c, 1);
	draw3d->settransform(d3c, cf_xform);
	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
}

solid(mx, my: int): int
{
	if(mx < 0 || mx >= MW || my < 0 || my >= MH)
		return 1;
	return map[my][mx] == T_EMPTY;
}

draw_wall(x0, z0, x1, z1: real, c: ref Image)
{
	h := WALL_H;
	draw3d->setcolour(d3c, c);
	# TempleOS draws the castle as opaque GrFillPoly3 panels.  A normal with a
	# non-zero z component also lets the software renderer maintain panel depth.
	verts := array[] of {
		Vector(x0, 0.0, z0), Vector(x1, 0.0, z1),
		Vector(x1, h, z1), Vector(x0, h, z0)
	};
	fill_world_poly(verts, Vector(z1-z0, 0.0, x0-x1), 0.82);
}

camera_depth(v: Vector): real
{
	return (v.x-cam_x)*math->cos(cam_a) - (v.z-cam_y)*math->sin(cam_a);
}

fill_world_poly(verts: array of Vector, normal: Vector, lit: real)
{
	# Clip in world space against the custom camera's near plane.  draw3d cannot
	# infer this plane from an arbitrary Limbo transform, and rejecting a quad
	# when one vertex is behind the eye leaves large black wedges.
	if(len verts < 3)
		return;
	out := array[len verts+2] of Vector;
	n := 0;
	a := verts[len verts-1];
	da := camera_depth(a);
	for(i := 0; i < len verts; i++){
		b := verts[i];
		db := camera_depth(b);
		ain := da >= NEAR;
		bin := db >= NEAR;
		if(ain != bin){
			t := (NEAR-da)/(db-da);
			out[n++] = Vector(a.x+t*(b.x-a.x), a.y+t*(b.y-a.y),
				a.z+t*(b.z-a.z));
		}
		if(bin)
			out[n++] = b;
		a = b;
		da = db;
	}
	if(n >= 3)
		draw3d->fillpoly3(d3c, out[0:n], normal, lit);
}

draw_floor_tile(mx, my: int)
{
	x0 := real mx;
	z0 := real my;
	x1 := x0 + 1.0;
	z1 := z0 + 1.0;
	# These are the exact source-map materials: DKGRAY for corridors and the
	# yellow statue cells, GREEN for plants, and BLUE for the divider.
	c := palette[8];
	if(map[my][mx] == T_PLANT)
		c = palette[2];
	else if(map[my][mx] == T_BLOCK)
		c = palette[1];
	draw3d->setcolour(d3c, c);
	verts := array[] of {
		Vector(x0, 0.0, z0), Vector(x0, 0.0, z1),
		Vector(x1, 0.0, z1), Vector(x1, 0.0, z0)
	};
	fill_world_poly(verts, Vector(0.0, 1.0, 0.001), 0.62);
}

cell_walls(mx, my: int)
{
	x0 := real mx;
	z0 := real my;
	x1 := x0 + 1.0;
	z1 := z0 + 1.0;
	if(solid(mx, my-1))
		draw_wall(x0, z0, x1, z0, palette[7]);
	if(solid(mx, my+1))
		draw_wall(x0, z1, x1, z1, palette[7]);
	if(solid(mx-1, my))
		draw_wall(x0, z0, x0, z1, palette[15]);
	if(solid(mx+1, my))
		draw_wall(x1, z0, x1, z1, palette[15]);
}

bill_insert(bills: array of Bill, n: int, b: Bill): int
{
	# insert by descending dist (far first)
	i := n;
	while(i > 0 && bills[i-1].dist < b.dist){
		bills[i] = bills[i-1];
		i--;
	}
	bills[i] = b;
	return n + 1;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	cx := w / 2;
	cy := h / 2;

	# TempleOS clears the document to black; there is no invented sky texture.
	img.draw(img.r, palette[0], nil, Point(0, 0));
	setup3d(img);

	# Refresh gameplay/HUD visibility separately from world geometry.  A tile
	# centre can be hidden while part of one of its boundary walls is visible;
	# using centre-point LOS to cull panels created black gaps at corners.
	# Submit every nearby occupied tile and let the z buffer clip it correctly.
	for(my := 0; my < MH; my++)
		for(mx := 0; mx < MW; mx++){
			vis := 0;
			if(map[my][mx] != T_EMPTY)
				vis = los(cell(cam_x), cell(cam_y), mx, my);
			visible[my][mx] = vis;
			if(map[my][mx] == T_EMPTY)
				continue;
			draw_floor_tile(mx, my);
			cell_walls(mx, my);
		}

	bills := array[MONS + 64] of Bill;
	nb := 0;
	for(my = 0; my < MH; my++)
		for(mx = 0; mx < MW; mx++){
			if((map[my][mx] != T_PLANT && map[my][mx] != T_STATUE) || !visible[my][mx])
				continue;
			px := real mx + 0.5;
			pz := real my + 0.5;
			dd := (px - cam_x)*(px - cam_x) + (pz - cam_y)*(pz - cam_y);
			if(nb < len bills)
				nb = bill_insert(bills, nb, Bill(px, 0.35, pz, dd,
					3 * (map[my][mx] == T_STATUE)));
		}
	for(i := 0; i < MONS; i++){
		tx := cell(mon_x[i]);
		ty := cell(mon_y[i]);
		if(!visible[ty][tx])
			continue;
		px := mon_x[i];
		pz := mon_y[i];
		dd := (px - cam_x)*(px - cam_x) + (pz - cam_y)*(pz - cam_y);
			if(nb < len bills){
				kind := 1;
				if(mon_dead[i]) kind = 4;
				nb = bill_insert(bills, nb, Bill(px, 0.0, pz, dd, kind));
			}
	}
	if(sys->millisec() - fire_t0 < 150){
		fx := man_x + math->cos(cam_a) * 1.2;
		fz := man_y - math->sin(cam_a) * 1.2;
		if(nb < len bills)
			nb = bill_insert(bills, nb, Bill(fx, 0.5, fz, 1.0, 2));
	}

	for(bi := 0; bi < nb; bi++){
		b := bills[bi];
		(sp, ez, ok) := draw3d->project(d3c, Vector(b.x, b.y, b.z));
		if(!ok)
			continue;
		zd := -ez;
		if(zd < 0.4)
			zd = 0.4;
		case b.kind {
		0 =>
			if(meshes[5] != nil){
				draw_mesh(meshes[5], b.x, b.z, 2.0/512.0);
				continue;
			}
			rad := int(18.0 / zd);
			if(rad < 2) rad = 2;
			if(rad > 28) rad = 28;
			img.fillellipse(sp, rad, rad + rad/3, plantc, Point(0, 0));
		1 =>
			if(meshes[3] != nil && meshes[4] != nil){
				p := real(sys->millisec()%1000)/1000.0;
				if(p < 0.5) p *= 2.0; else p = 2.0*(1.0-p);
				draw_mesh_interp(meshes[3], meshes[4], p,
					b.x, b.z, 2.0/512.0);
				continue;
			}
			rad := int(28.0 / zd);
			if(rad < 3) rad = 3;
			if(rad > 40) rad = 40;
			img.fillellipse(sp, rad, rad + rad/2, monsc, Point(0, 0));
			img.fillellipse(Point(sp.x, sp.y - rad), rad/2, rad/2, red, Point(0, 0));
		2 =>
			img.fillellipse(sp, 5, 5, yellow, Point(0, 0));
		3 =>
			if(meshes[6] != nil){
				draw_mesh(meshes[6], b.x, b.z, 2.0/512.0);
				continue;
			}
			rad := int(22.0 / zd);
			if(rad < 3) rad = 3;
			if(rad > 34) rad = 34;
			img.draw(Rect((sp.x-rad/2, sp.y-rad),
				(sp.x+rad/2, sp.y+rad)), yellow, nil, Point(0, 0));
		4 =>
			if(meshes[2] != nil)
				draw_dead_mesh(meshes[2], b.x, b.z, 2.0/512.0);
		}
	}

	# crosshair
	img.line(Point(o.x+cx-6, o.y+cy), Point(o.x+cx+6, o.y+cy), 0, 0, 0, yellow, Point(0, 0));
	img.line(Point(o.x+cx, o.y+cy-6), Point(o.x+cx, o.y+cy+6), 0, 0, 0, yellow, Point(0, 0));

	# TempleOS keeps its tactical map in the lower-right corner.
	mmx := o.x + w - 2*MW - 4;
	mmy := o.y + h - 2*MH - 22;
	# This backing deliberately differs from the black world clear.  The Metal
	# compositor identifies post-3D overlays by their difference from that
	# snapshot, so an identical black backing would incorrectly let walls show.
	img.draw(Rect((mmx-2, mmy-2), (mmx+2*MW+2, mmy+2*MH+2)), hudbg, nil, Point(0, 0));
	for(my = 0; my < MH; my++)
		for(mx = 0; mx < MW; mx++){
			if(map[my][mx] == T_EMPTY)
				continue;
			mc := floorc;
			if(map[my][mx] == T_PLANT)
				mc = plantc;
			else if(map[my][mx] == T_BLOCK)
				mc = blue;
			else if(map[my][mx] == T_STATUE)
				mc = yellow;
			if(visible[my][mx])
				img.draw(Rect((mmx+2*mx, mmy+2*my), (mmx+2*mx+1, mmy+2*my+1)), mc, nil, Point(0, 0));
			else
				img.draw(Rect((mmx+2*mx, mmy+2*my), (mmx+2*mx+1, mmy+2*my+1)), fog, nil, Point(0, 0));
		}
	for(mi := 0; mi < MONS; mi++)
		if(!mon_dead[mi])
			img.draw(Rect((mmx+2*cell(mon_x[mi]), mmy+2*cell(mon_y[mi])),
				(mmx+2*cell(mon_x[mi])+1, mmy+2*cell(mon_y[mi])+1)), red, nil, Point(0, 0));
	img.draw(Rect((mmx+2*cell(man_x), mmy+2*cell(man_y)),
		(mmx+2*cell(man_x)+1, mmy+2*cell(man_y)+1)), cyan, nil, Point(0, 0));
	# facing tick
	ex := mmx + 2*cell(man_x) + int(math->cos(cam_a)*3.0);
	ey := mmy + 2*cell(man_y) - int(math->sin(cam_a)*3.0);
	img.line(Point(mmx+2*cell(man_x), mmy+2*cell(man_y)), Point(ex, ey), 0, 0, 0, yellow, Point(0, 0));

	if(font != nil){
		img.draw(Rect((o.x, o.y+h-20), (o.x+w, o.y+h)), hudbg, nil, Point(0, 0));
		elapsed := real(sys->millisec() - t0) / 1000.0;
		if(tf)
			elapsed = real(tf - t0) / 1000.0;
		msg := sys->sprint("Enemy:%d Time:%3.2fs Best:%3.2fs", monsters_left, elapsed, best_score);
		img.text(Point(o.x+4, o.y+h-16), green, Point(0, 0), font, msg);
		if(tf && blink_on)
			img.text(Point(o.x+cx-56, o.y+cy), red, Point(0, 0), font, "Game Completed");
	}
	img.flush(Draw->Flushnow);
}

absi(v: int): int
{
	if(v < 0) return -v;
	return v;
}

cell(v: real): int
{
	# Limbo real-to-int conversion rounds; TempleOS map indexing truncates the
	# positive fixed-point coordinate.  Explicit floor is required at .5 cells.
	return int math->floor(v);
}

min(a, b: int): int
{
	if(a < b) return a;
	return b;
}

max(a, b: int): int
{
	if(a > b) return a;
	return b;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

mon_timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

castle_song()
{
	# Original CastleFrankenstein score (TempleOS Play() notation).
	for(;;)
		tone->play("3q.A#eGAeA#qAq.A#eGeAeA#qA" +
			"3q.A#eGA#AqGq.A#eGA#AqG" +
			"4eA#AqGeA#AqGeA#AGAA#AqG");
}

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[32768] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	(nil, lines) := sys->tokenize(s, "\n");
	if(lines == nil)
		return nil;
	(nil, h) := sys->tokenize(hd lines, " \t");
	if(len h != 3 || hd h != "mesh")
		return nil;
	nv := int hd tl h;
	nf := int hd tl tl h;
	m := ref Mesh(array[nv] of Vector, array[nf] of Tri);
	vi := fi := 0;
	for(lines = tl lines; lines != nil; lines = tl lines){
		(nil, t) := sys->tokenize(hd lines, " \t\r");
		if(t == nil)
			continue;
		if(hd t == "v" && len t == 4 && vi < nv){
			t = tl t;
			x := int hd t; t = tl t;
			y := int hd t; t = tl t;
			z := int hd t;
			m.v[vi++] = Vector(real x, real y, real z);
		}else if(hd t == "f" && len t == 5 && fi < nf){
			t = tl t;
			c := int hd t; t = tl t;
			a := int hd t; t = tl t;
			b := int hd t; t = tl t;
			d := int hd t;
			m.f[fi++] = Tri(c, a, b, d);
		}
	}
	if(vi != nv || fi != nf)
		return nil;
	return m;
}

draw_mesh(m: ref Mesh, x, z, scale: real)
{
	draw_mesh_rot(m, x, z, scale, 0.0, 0);
}

draw_dead_mesh(m: ref Mesh, x, z, scale: real)
{
	draw_mesh_rot(m, x, z, scale, 0.0, 1);
}

draw_mesh_rot(m: ref Mesh, x, z, scale, angle: real, dead: int)
{
	if(m == nil)
		return;
	sa := math->sin(angle);
	ca := math->cos(angle);
	wv := array[len m.v] of Vector;
	for(i := 0; i < len m.v; i++){
		v := m.v[i];
		if(dead)
			# The corpse uses only Mat4x4Scale: sprite Z remains world-up.
			wv[i] = Vector(x+scale*v.x, scale*v.z, z+scale*v.y);
		else{
			# Plants/statues use RotX(-PI/2); live monsters additionally rotate
			# around world-up by tS rather than billboarding toward the camera.
			lx := v.x*ca-v.z*sa;
			lz := v.x*sa+v.z*ca;
			wv[i] = Vector(x+scale*lx, -scale*v.y, z+scale*lz);
		}
	}
	for(i = 0; i < len m.f; i++){
		f := m.f[i];
		if(f.a >= len wv || f.b >= len wv || f.c >= len wv)
			continue;
		a := wv[f.a]; b := wv[f.b]; c := wv[f.c];
		n := draw3d->vcross(Vector(b.x-a.x, b.y-a.y, b.z-a.z),
			Vector(c.x-a.x, c.y-a.y, c.z-a.z));
		col := f.colour & 15;
		draw3d->setcolour(d3c, palette[col]);
		fill_world_poly(array[] of {a, b, c}, n, 1.0);
	}
}

draw_mesh_interp(a, b: ref Mesh, t, x, z, scale: real)
{
	if(a == nil || b == nil || len a.v != len b.v || len a.f != len b.f){
		draw_mesh(a, x, z, scale);
		return;
	}
	m := interpmesh;
	if(m == nil || len m.v != len a.v){
		m = ref Mesh(array[len a.v] of Vector, a.f);
		interpmesh = m;
	}
	for(i := 0; i < len a.v; i++)
		m.v[i] = Vector(a.v[i].x+t*(b.v[i].x-a.v[i].x),
			a.v[i].y+t*(b.v[i].y-a.v[i].y),
			a.v[i].z+t*(b.v[i].z-a.v[i].z));
	draw_mesh_rot(m, x, z, scale, real sys->millisec()/1000.0, 0);
}
