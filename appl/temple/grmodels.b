implement Grmodels;

# TempleOS Apps/GrModels — UV-sphere + stick-man mesh viewer
# GAP: no DolDoc mesh export, ManGen joint editor, CSprite cut-paste

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

Grmodels: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Mesh: adt {
	nv: int;
	vx, vy, vz: array of real;
	nt: int;
	t0, t1, t2: array of int;
};

win: ref Window;
ink: array of ref Image;
mesh: Mesh;
mode := 0;	# 0 ball, 1 man
yaw := 0.0;
pitch := 0.3;
zoom := 1.0;
ball_rad := 20.0;
ball_lon := 16;
ball_lat := 8;
drag := 0;
last_mx := 0;
last_my := 0;
fill_faces := 1;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS GrModels", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	regen();

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
		case k {
		Keyboard->Esc or 'q' or 'Q' =>
			exit;
		'b' or 'B' =>
			mode = 0; regen();
		'm' or 'M' =>
			mode = 1; regen();
		'\n' =>
			regen();
		'+' or '=' =>
			zoom *= 1.1;
		'-' or '_' =>
			zoom /= 1.1;
			if(zoom < 0.2)
				zoom = 0.2;
		Keyboard->Left =>
			yaw -= 0.08;
		Keyboard->Right =>
			yaw += 0.08;
		Keyboard->Up =>
			pitch += 0.08;
		Keyboard->Down =>
			pitch -= 0.08;
		'f' or 'F' =>
			fill_faces = fill_faces ^ 1;
		}
	<-ticks =>
		if(drag)
			redraw();
	}
}

regen()
{
	if(mode == 0){
		ball_rad = 15.0 + 10.0 * rnreal();
		ball_lon = 12 + rn(8);
		ball_lat = 6 + rn(6);
		mesh = gen_ball(ball_rad, ball_lon, ball_lat);
	}else
		mesh = gen_man();
	redraw();
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	lb := (p.buttons & 1) != 0;
	if(lb){
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

ball_vmap: list of (int, int, int, int);
ball_nv: int;
ball_vx, ball_vy, ball_vz: array of real;

ball_addv(x, y, z: real): int
{
	kx := int(x*1000.0);
	ky := int(y*1000.0);
	kz := int(z*1000.0);
	for(vl := ball_vmap; vl != nil; vl = tl vl){
		(vkx, vky, vkz, idx) := hd vl;
		if(vkx == kx && vky == ky && vkz == kz)
			return idx;
	}
	idx := ball_nv;
	ball_nv++;
	ball_vx[idx] = x;
	ball_vy[idx] = y;
	ball_vz[idx] = z;
	ball_vmap = (kx, ky, kz, idx) :: ball_vmap;
	return idx;
}

gen_ball(r: real, m_lon, n_lat: int): Mesh
{
	n := n_lat * 2;
	m := m_lon;
	da1 := math->Pi / 2.0 / real n;
	da2 := math->Pi / real m;
	ball_vmap = nil;
	ball_nv = 0;
	ball_vx = array[1024] of { * => 0.0 };
	ball_vy = array[1024] of { * => 0.0 };
	ball_vz = array[1024] of { * => 0.0 };

	tris: list of (int, int, int);
	for(j := -n; j < n; j++){
		r1 := r * math->cos(real j * da1);
		r2 := r * math->cos(real (j+1) * da1);
		z1 := r * math->sin(real j * da1);
		z2 := r * math->sin(real (j+1) * da1);
		for(i := 0; i < m; i++){
			p1 := ball_addv(r1*math->cos(real(2*i+j)*da2), r1*math->sin(real(2*i+j)*da2), z1);
			p2 := ball_addv(r1*math->cos(real(2*i+2+j)*da2), r1*math->sin(real(2*i+2+j)*da2), z1);
			p3 := ball_addv(r2*math->cos(real(2*i+1+j)*da2), r2*math->sin(real(2*i+1+j)*da2), z2);
			p4 := ball_addv(r2*math->cos(real(2*i+3+j)*da2), r2*math->sin(real(2*i+3+j)*da2), z2);
			tris = (p1, p2, p3) :: tris;
			tris = (p3, p2, p4) :: tris;
		}
	}
	nv := ball_nv;
	vx := array[nv] of { * => 0.0 };
	vy := array[nv] of { * => 0.0 };
	vz := array[nv] of { * => 0.0 };
	for(i := 0; i < nv; i++){
		vx[i] = ball_vx[i];
		vy[i] = ball_vy[i];
		vz[i] = ball_vz[i];
	}
	nt := len tris;
	t0 := array[nt] of { * => 0 };
	t1 := array[nt] of { * => 0 };
	t2 := array[nt] of { * => 0 };
	i = 0;
	for(trl := tris; trl != nil; trl = tl trl){
		(a, b, c) := hd trl;
		t0[i] = a; t1[i] = b; t2[i] = c;
		i++;
	}
	return Mesh(nv, vx, vy, vz, nt, t0, t1, t2);
}

add_box(m: ref Mesh, x0, y0, z0, x1, y1, z1: real)
{
	jj, k: int;
	a, b, c: int;
	x, y, z: real;
	base := m.nv;
	pts := array[] of {
		(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
		(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)
	};
	n := len pts;
	ovx := m.vx;
	ovy := m.vy;
	ovz := m.vz;
	m.vx = array[base+n] of { * => 0.0 };
	m.vy = array[base+n] of { * => 0.0 };
	m.vz = array[base+n] of { * => 0.0 };
	for(jj = 0; jj < base; jj++){
		m.vx[jj] = ovx[jj];
		m.vy[jj] = ovy[jj];
		m.vz[jj] = ovz[jj];
	}
	for(jj = 0; jj < n; jj++){
		(x, y, z) = pts[jj];
		m.vx[base+jj] = x;
		m.vy[base+jj] = y;
		m.vz[base+jj] = z;
	}
	m.nv = base + n;
	faces := array[] of {
		(0,1,2), (0,2,3), (4,6,5), (4,7,6),
		(0,4,5), (0,5,1), (1,5,6), (1,6,2),
		(2,6,7), (2,7,3), (3,7,4), (3,4,0)
	};
	nt := m.nt + len faces;
	t0 := array[nt] of { * => 0 };
	t1 := array[nt] of { * => 0 };
	t2 := array[nt] of { * => 0 };
	for(jj = 0; jj < m.nt; jj++){
		t0[jj] = m.t0[jj]; t1[jj] = m.t1[jj]; t2[jj] = m.t2[jj];
	}
	for(jj = 0; jj < len faces; jj++){
		(a, b, c) = faces[jj];
		k = m.nt + jj;
		t0[k] = base + a; t1[k] = base + b; t2[k] = base + c;
	}
	m.nt = nt;
	m.t0 = t0; m.t1 = t1; m.t2 = t2;
}

gen_man(): Mesh
{
	m := Mesh(0,
		array[0] of { * => 0.0 },
		array[0] of { * => 0.0 },
		array[0] of { * => 0.0 },
		0,
		array[0] of { * => 0 },
		array[0] of { * => 0 },
		array[0] of { * => 0 }
	);
	# head
	add_box(ref m, -4.0, 30.0, -4.0, 4.0, 38.0, 4.0);
	# torso
	add_box(ref m, -6.0, 10.0, -3.0, 6.0, 30.0, 3.0);
	# arms
	add_box(ref m, -18.0, 18.0, -2.0, -6.0, 22.0, 2.0);
	add_box(ref m, 6.0, 18.0, -2.0, 18.0, 22.0, 2.0);
	# legs
	add_box(ref m, -5.0, -20.0, -2.5, -1.0, 10.0, 2.5);
	add_box(ref m, 1.0, -20.0, -2.5, 5.0, 10.0, 2.5);
	# feet
	add_box(ref m, -6.0, -24.0, -4.0, 0.0, -20.0, 8.0);
	add_box(ref m, 0.0, -24.0, -4.0, 6.0, -20.0, 8.0);
	return m;
}

project(x, y, z: real): (int, int, real)
{
	img := win.image;
	cx := 320; cy := 240;
	if(img != nil){
		cx = img.r.dx() / 2;
		cy = img.r.dy() / 2;
	}
	ca := math->cos(yaw);
	sa := math->sin(yaw);
	x1 := x*ca + z*sa;
	z1 := -x*sa + z*ca;
	cb := math->cos(pitch);
	sb := math->sin(pitch);
	y2 := y*cb - z1*sb;
	z2 := y*sb + z1*cb;
	if(z2 < 0.5)
		z2 = 0.5;
	s := 4.0 * zoom / (4.0 + z2/20.0);
	return (cx + int(x1*s), cy + int(y2*s), z2);
}

redraw()
{
	i, j, ii, a, b, c: int;
	ax, ay, bx, by, cx, cy: int;
	px, py: int;
	zd, za, zb, zc: real;
	tmp, shade: int;
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[0], nil, Point(0, 0));

	fz: array of real;
	fz = array[mesh.nt] of { * => 0.0 };
	for(i = 0; i < mesh.nt; i++){
		a = mesh.t0[i]; b = mesh.t1[i]; c = mesh.t2[i];
		(px, py, za) = project(mesh.vx[a], mesh.vy[a], mesh.vz[a]);
		(px, py, zb) = project(mesh.vx[b], mesh.vy[b], mesh.vz[b]);
		(px, py, zc) = project(mesh.vx[c], mesh.vy[c], mesh.vz[c]);
		fz[i] = (za + zb + zc) / 3.0;
	}
	order := array[mesh.nt] of { * => 0 };
	for(i = 0; i < mesh.nt; i++)
		order[i] = i;
	for(i = 0; i < mesh.nt; i++){
		for(j = i+1; j < mesh.nt; j++){
			if(fz[order[j]] < fz[order[i]]){
				tmp = order[i];
				order[i] = order[j];
				order[j] = tmp;
			}
		}
	}

	if(fill_faces){
		for(ii = 0; ii < mesh.nt; ii++){
			i = order[ii];
			a = mesh.t0[i]; b = mesh.t1[i]; c = mesh.t2[i];
			(ax, ay, zd) = project(mesh.vx[a], mesh.vy[a], mesh.vz[a]);
			(bx, by, zd) = project(mesh.vx[b], mesh.vy[b], mesh.vz[b]);
			(cx, cy, zd) = project(mesh.vx[c], mesh.vy[c], mesh.vz[c]);
			shade = int(8.0 + 4.0 * fz[i] / (ball_rad + 30.0));
			if(shade > 15)
				shade = 15;
			if(shade < 1)
				shade = 1;
			fill_tri(img, o, ax, ay, bx, by, cx, cy, ink[shade]);
		}
	}

	for(i = 0; i < mesh.nt; i++){
		a = mesh.t0[i]; b = mesh.t1[i]; c = mesh.t2[i];
		(ax, ay, zd) = project(mesh.vx[a], mesh.vy[a], mesh.vz[a]);
		(bx, by, zd) = project(mesh.vx[b], mesh.vy[b], mesh.vz[b]);
		(cx, cy, zd) = project(mesh.vx[c], mesh.vy[c], mesh.vz[c]);
		pa := Point(ax, ay).add(o);
		pb := Point(bx, by).add(o);
		pc := Point(cx, cy).add(o);
		col := ink[14];
		if(mode == 1)
			col = ink[11];
		img.line(pa, pb, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
		img.line(pb, pc, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
		img.line(pc, pa, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

fill_tri(img: ref Image, o: Point, x0, y0, x1, y1, x2, y2: int, col: ref Image)
{
	# scanline fill via edge function
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
		xa := 1000000; xb := -1000000;
		for(xl := xs; xl != nil; xl = tl xl){
			x := hd xl;
			if(x < xa) xa = x;
			if(x > xb) xb = x;
		}
		if(xa <= xb)
			img.draw(Rect((o.x+xa, o.y+y), (o.x+xb+1, o.y+y+1)), col, nil, Point(0, 0));
	}
}

scan_edge(x0, y0, x1, y1, y: int, xs: list of int): list of int
{
	if(y0 == y1)
		return xs;
	if((y < y0 && y < y1) || (y > y0 && y > y1))
		return xs;
	t := real(y - y0) / real(y1 - y0);
	x := int(real x0 + t * real(x1 - x0));
	return x :: xs;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000)) / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
