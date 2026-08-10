implement Draw3d;

# Common Inferno software-3D: matrix stack (from wm/collide), Polyfill z-buffer,
# and TempleOS-capable Sprite3 / Gr*3-style helpers.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Point, Rect, Image: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
	polyfill: Polyfill;
	Zstate: import polyfill;

include "math/draw3d.m";

∞: con real (1<<30);
LIMIT: con real (1<<11);
Pi: con Math->Pi;

Mstate: adt
{
	matl: list of Matrix;
	modl: list of Matrix;
	prjl: list of Matrix;
	mull: Matrix;
	freel: list of Matrix;
	vk: int;
	vr: int;
	vrr: int;
	ap: array of Point;
	apn: int;
	ignore: int;
	cur: ref Context;
};

ms: Mstate;
inited := 0;

init()
{
	if(inited)
		return;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	polyfill = load Polyfill Polyfill->PATH;
	if(polyfill == nil){
		sys->fprint(sys->fildes(2), "draw3d: cannot load polyfill: %r\n");
		raise "fail:load";
	}
	polyfill->init();
	inited = 1;
}

ensure()
{
	if(!inited)
		init();
}

newmatrix(): Matrix
{
	ensure();
	if(ms.freel != nil){
		m := hd ms.freel;
		ms.freel = tl ms.freel;
		return m;
	}
	m := array[4] of array of real;
	for(i := 0; i < 4; i++)
		m[i] = array[4] of { * => 0.0 };
	return m;
}

mfree(m: Matrix)
{
	ms.freel = m :: ms.freel;
}

context(dst: ref Image): ref Context
{
	ensure();
	c := ref Context;
	c.dst = dst;
	c.zenable = 1;
	c.clipbehind = 1;
	c.colour = nil;
	c.transform = nil;
	if(dst != nil){
		c.zstate = polyfill->initzbuf(dst.r);
		viewport(c, dst.r.min.x, dst.r.min.y, dst.r.max.x, dst.r.max.y);
	}
	# matrix stacks
	ms.modl = newmatrix() :: nil;
	ms.prjl = newmatrix() :: nil;
	ms.matl = ms.modl;
	ms.mull = newmatrix();
	ms.vk = 0;
	ms.apn = 0;
	ms.ignore = 0;
	ms.cur = c;
	identity();
	mode(PROJ);
	identity();
	mode(MODEL);
	identity();
	return c;
}

resize(c: ref Context, dst: ref Image)
{
	ensure();
	c.dst = dst;
	if(dst != nil){
		c.zstate = polyfill->initzbuf(dst.r);
		viewport(c, dst.r.min.x, dst.r.min.y, dst.r.max.x, dst.r.max.y);
	}else
		c.zstate = nil;
	ms.cur = c;
}

setzarea(c: ref Context, r: Rect)
{
	ensure();
	if(c == nil)
		return;
	if(r.dx() > 0 && r.dy() > 0)
		c.zstate = polyfill->initzbuf(r);
	else
		c.zstate = nil;
}

clearz(c: ref Context)
{
	if(c != nil && c.zstate != nil)
		polyfill->clearzbuf(c.zstate);
}

setz(c: ref Context, on: int)
{
	c.zenable = on;
}

setzclip(c: ref Context, on: int)
{
	c.clipbehind = on;
}

setcolour(c: ref Context, col: ref Image)
{
	c.colour = col;
}

settransform(c: ref Context, t: ref fn(v: Vector): Vector)
{
	c.transform = t;
}

viewport(c: ref Context, x1, y1, x2, y2: int)
{
	c.mx = real (x2 - x1) / 2.0;
	c.cx = real (x2 + x1) / 2.0;
	c.my = real (y2 - y1) / 2.0;
	c.cy = real (y2 + y1) / 2.0;
}

mode(which: int)
{
	if(which == PROJ)
		ms.matl = ms.prjl;
	else
		ms.matl = ms.modl;
}

push()
{
	if(ms.matl == ms.modl){
		ms.modl = newmatrix() :: ms.modl;
		ms.matl = ms.modl;
	}else{
		ms.prjl = newmatrix() :: ms.prjl;
		ms.matl = ms.prjl;
	}
	s := hd tl ms.matl;
	d := hd ms.matl;
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++)
			d[i][j] = s[i][j];
}

pop()
{
	if(ms.matl == ms.modl){
		mfree(hd ms.modl);
		ms.modl = tl ms.modl;
		ms.matl = ms.modl;
	}else{
		mfree(hd ms.prjl);
		ms.prjl = tl ms.prjl;
		ms.matl = ms.prjl;
	}
}

identity()
{
	m := hd ms.matl;
	for(i := 0; i < 4; i++){
		for(j := 0; j < 4; j++)
			m[i][j] = 0.0;
		m[i][i] = 1.0;
	}
}

translate(x, y, z: real)
{
	m := hd ms.matl;
	for(i := 0; i < 4; i++)
		m[i][3] = x*m[i][0] + y*m[i][1] + z*m[i][2] + m[i][3];
}

scale(x, y, z: real)
{
	m := hd ms.matl;
	for(i := 0; i < 4; i++){
		m[i][0] *= x;
		m[i][1] *= y;
		m[i][2] *= z;
	}
}

rot(deg: real, j: int, k: int)
{
	m := hd ms.matl;
	rad := Pi * deg / 180.0;
	s := math->sin(rad);
	c := math->cos(rad);
	for(i := 0; i < 4; i++){
		a := m[i][j];
		b := m[i][k];
		m[i][j] = c*a + s*b;
		m[i][k] = c*b - s*a;
	}
}

rotatex(a: real)
{
	rot(a, 1, 2);
}

rotatey(a: real)
{
	rot(a, 2, 0);
}

rotatez(a: real)
{
	rot(a, 0, 1);
}

rotate(deg, l, m, n: real)
{
	mx := hd ms.matl;
	rad := Pi * deg / 180.0;
	s := math->sin(rad);
	c := math->cos(rad);
	f := 1.0 - c;
	for(i := 0; i < 4; i++){
		m0 := mx[i][0];
		m1 := mx[i][1];
		m2 := mx[i][2];
		mx[i][0] = m0*(l*l*f+c) + m1*(l*m*f+n*s) + m2*(l*n*f-m*s);
		mx[i][1] = m0*(l*m*f-n*s) + m1*(m*m*f+c) + m2*(m*n*f+l*s);
		mx[i][2] = m0*(l*n*f+m*s) + m1*(m*n*f-l*s) + m2*(n*n*f+c);
	}
}

frustum(l, n, f: real)
{
	m := hd ms.matl;
	r := n / l;
	f = ∞;
	for(i := 0; i < 4; i++){
		a := m[i][2];
		b := m[i][3];
		m[i][0] *= r;
		m[i][1] *= r;
		m[i][2] = a + b;
		m[i][3] = 0.0;
	}
}

ortho(l, n, f: real)
{
	m := hd ms.matl;
	r := 1.0 / l;
	n = 0.0;
	f = ∞;
	for(i := 0; i < 4; i++){
		m[i][0] *= r;
		m[i][1] *= r;
	}
}

loadmatrix(u: Matrix)
{
	m := hd ms.matl;
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++)
			m[i][j] = u[i][j];
}

storematrix(u: Matrix)
{
	m := hd ms.matl;
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++)
			u[i][j] = m[i][j];
}

matmul()
{
	m := hd ms.modl;
	p := hd ms.prjl;
	r := ms.mull;
	for(i := 0; i < 4; i++){
		pr := p[i];
		rr := r[i];
		for(j := 0; j < 4; j++)
			rr[j] = pr[0]*m[0][j] + pr[1]*m[1][j] + pr[2]*m[2][j] + pr[3]*m[3][j];
	}
}

mulpoint(m: Matrix, v: Vector): Vector
{
	x := v.x; y := v.y; z := v.z;
	x1 := x*m[0][0] + y*m[0][1] + z*m[0][2] + m[0][3];
	y1 := x*m[1][0] + y*m[1][1] + z*m[1][2] + m[1][3];
	z1 := x*m[2][0] + y*m[2][1] + z*m[2][2] + m[2][3];
	w := x*m[3][0] + y*m[3][1] + z*m[3][2] + m[3][3];
	if(w != 0.0 && w != 1.0){
		x1 /= w; y1 /= w; z1 /= w;
	}
	return Vector(x1, y1, z1);
}

# Model → eye (+ optional transform). Returns (eye, ok).
toeye(c: ref Context, v: Vector): (Vector, int)
{
	e := mulpoint(hd ms.modl, v);
	tf := c.transform;
	if(tf != nil)
		e = tf(e);
	if(c.clipbehind && e.z >= 0.0)
		return (e, 0);
	return (e, 1);
}

# Eye → clip/NDC xy via projection matrix. Returns (x, y, ok).
toclip(e: Vector): (real, real, int)
{
	m := hd ms.prjl;
	x1 := e.x*m[0][0] + e.y*m[0][1] + e.z*m[0][2] + m[0][3];
	y1 := e.x*m[1][0] + e.y*m[1][1] + e.z*m[1][2] + m[1][3];
	w := e.x*m[3][0] + e.y*m[3][1] + e.z*m[3][2] + m[3][3];
	if(w == 0.0)
		return (x1, y1, 0);
	if(w != 1.0){
		x1 /= w;
		y1 /= w;
	}
	return (x1, y1, 1);
}

# Eye-space via model, optional transform, then projection to screen.
project(c: ref Context, v: Vector): (Point, real, int)
{
	ms.cur = c;
	matmul();
	(e, ok) := toeye(c, v);
	if(!ok)
		return (Point(0, 0), e.z, 0);
	(x1, y1, ok2) := toclip(e);
	if(!ok2)
		return (Point(0, 0), e.z, 0);
	sx := int (c.mx * x1 + c.cx);
	sy := int (c.my * y1 + c.cy);
	return (Point(sx, sy), e.z, 1);
}

begin(c: ref Context, kind, nvert: int)
{
	ms.cur = c;
	ms.ignore = 0;
	ms.vk = kind;
	ms.ap = array[nvert + 1] of Point;
	ms.apn = 0;
	matmul();
}

# Same model→transform→proj path as project; returns clip xy for circle sizing.
vertex(c: ref Context, x, y, z: real): (real, real)
{
	ms.cur = c;
	(e, ok) := toeye(c, Vector(x, y, z));
	if(!ok){
		ms.ignore = 1;
		return (0.0, 0.0);
	}
	(x1, y1, ok2) := toclip(e);
	if(!ok2){
		ms.ignore = 1;
		return (x1, y1);
	}
	ms.ap[ms.apn++] = Point(int (c.mx*x1 + c.cx), int (c.my*y1 + c.cy));
	return (x1, y1);
}

circle(c: ref Context, x, y, z, r: real)
{
	(d, nil) := vertex(c, x, y, z);
	(e, nil) := vertex(c, x+r, y, z);
	d -= e;
	if(d < 0.0)
		d = -d;
	ms.vr = int (c.mx * d);
}

ellipse(c: ref Context, x, y, z: real, axes: Vector)
{
	circle(c, x, y, z, axes.x);
	(nil, d) := vertex(c, x, y, z);
	(nil, e) := vertex(c, x, y+axes.y, z);
	d -= e;
	if(d < 0.0)
		d = -d;
	ms.vrr = int (c.my * d);
}

end(c: ref Context)
{
	if(ms.ignore || c.dst == nil || c.colour == nil)
		return;
	dst := c.dst;
	vc := c.colour;
	case ms.vk {
	CIRCLE =>
		dst.ellipse(ms.ap[0], ms.vr, ms.vr, 0, vc, Point(0, 0));
	FILLCIRCLE =>
		dst.fillellipse(ms.ap[0], ms.vr, ms.vr, vc, Point(0, 0));
	ELLIPSE =>
		dst.ellipse(ms.ap[0], ms.vr, ms.vrr, 0, vc, Point(0, 0));
	FILLELLIPSE =>
		dst.fillellipse(ms.ap[0], ms.vr, ms.vrr, vc, Point(0, 0));
	POLY =>
		ms.ap[len ms.ap - 1] = ms.ap[0];
		dst.poly(ms.ap, Draw->Endsquare, Draw->Endsquare, 0, vc, Point(0, 0));
	FILLPOLY =>
		ms.ap[len ms.ap - 1] = ms.ap[0];
		dst.fillpoly(ms.ap, ~0, vc, Point(0, 0));
	}
}

line3(c: ref Context, a, b: Vector, thick: int)
{
	(pa, nil, oka) := project(c, a);
	(pb, nil, okb) := project(c, b);
	if(!oka || !okb || c.dst == nil || c.colour == nil)
		return;
	if(thick < 0)
		thick = 0;
	c.dst.line(pa, pb, Draw->Endsquare, Draw->Endsquare, thick, c.colour, Point(0, 0));
}

plot3(c: ref Context, v: Vector)
{
	(p, nil, ok) := project(c, v);
	if(!ok || c.dst == nil || c.colour == nil)
		return;
	c.dst.draw(Rect(p, p.add(Point(1, 1))), c.colour, nil, Point(0, 0));
}

fillpoly3(c: ref Context, verts: array of Vector, normal: Vector, lit: real)
{
	n := len verts;
	if(n < 3 || c.dst == nil || c.colour == nil)
		return;
	ap := array[n + 1] of Point;
	eye := array[n] of Vector;
	okn := 0;
	for(i := 0; i < n; i++){
		(p, z, ok) := project(c, verts[i]);
		if(!ok)
			return;
		ap[i] = p;
		eye[i] = Vector(real p.x, real p.y, z);
		okn++;
	}
	ap[n] = ap[0];
	if(c.zenable && c.zstate != nil && normal.z != 0.0){
		# Plane in screen space from face normal / centroid (polyhedra approach).
		f := normal;
		d := 0.0;
		for(i = 0; i < n; i++)
			d += vdot(f, verts[i]);
		d /= real n;
		α := c.mx;
		β := c.cx;
		γ := c.my;
		δ := c.cy;
		cz := f.z;
		if(cz > -1e-6 && cz < 1e-6){
			c.dst.fillpoly(ap, ~0, c.colour, Point(0, 0));
			return;
		}
		a := -f.x / (cz * α);
		b := -f.y / (cz * γ);
		dd := d / cz - β * a - δ * b;
		if(a <= -LIMIT || a >= LIMIT || b <= -LIMIT || b >= LIMIT || dd <= -LIMIT || dd >= LIMIT){
			c.dst.fillpoly(ap, ~0, c.colour, Point(0, 0));
			return;
		}
		dx := int (a * ZSCALE);
		dy := int (b * ZSCALE);
		dc := int (dd * ZSCALE);
		polyfill->fillpoly(c.dst, ap, ~0, c.colour, Point(0, 0), c.zstate, dc, dx, dy);
	}else
		c.dst.fillpoly(ap, ~0, c.colour, Point(0, 0));
	lit = lit;	# reserved for shade selection by caller
}

spriteat(c: ref Context, p: Vector, img, mask: ref Image, scale: real, degz: real)
{
	(sp, ez, ok) := project(c, p);
	if(!ok || c.dst == nil || img == nil)
		return;
	iw := img.r.dx();
	ih := img.r.dy();
	# Perspective scale: closer (more negative z) → larger
	sc := 1.0;
	if(scale > 0.0 && ez < 0.0)
		sc = scale / (-ez);
	else if(ez < 0.0)
		sc = 1.0 / (-ez);
	sw := int (real iw * sc);
	sh := int (real ih * sc);
	if(sw < 1) sw = 1;
	if(sh < 1) sh = 1;
	# Normalize angle; near 0 → fast axis-aligned blit
	while(degz >= 360.0)
		degz -= 360.0;
	while(degz < 0.0)
		degz += 360.0;
	if(degz < 0.5 || degz > 359.5){
		r := Rect((sp.x - sw/2, sp.y - sh/2), (sp.x - sw/2 + sw, sp.y - sh/2 + sh));
		c.dst.draw(r, img, mask, img.r.min);
		return;
	}
	rotsprite(c.dst, sp, sw, sh, img, mask, degz);
}

# Software Z-rotate blit (nearest-neighbour) for Sprite3ZB.
rotsprite(dst: ref Image, sp: Point, sw, sh: int, img, mask: ref Image, degz: real)
{
	iw := img.r.dx();
	ih := img.r.dy();
	if(iw < 1 || ih < 1 || sw < 1 || sh < 1)
		return;
	rad := Pi * degz / 180.0;
	cs := math->cos(rad);
	sn := math->sin(rad);
	# Bounding box of rotated rectangle
	hx := real sw / 2.0;
	hy := real sh / 2.0;
	maxe := 0.0;
	for(sx := -1; sx <= 1; sx += 2)
		for(sy := -1; sy <= 1; sy += 2){
			rx := real sx * hx * cs - real sy * hy * sn;
			ry := real sx * hx * sn + real sy * hy * cs;
			if(rx < 0.0) rx = -rx;
			if(ry < 0.0) ry = -ry;
			if(rx > maxe) maxe = rx;
			if(ry > maxe) maxe = ry;
		}
	bw := int (maxe * 2.0) + 2;
	bh := bw;
	if(bw < 2 || bh < 2)
		return;
	disp := dst.display;
	if(disp == nil)
		return;
	tmp := disp.newimage(Rect((0, 0), (bw, bh)), img.chans, 0, 0);
	if(tmp == nil)
		return;
	tmpm: ref Image = nil;
	if(mask != nil){
		tmpm = disp.newimage(Rect((0, 0), (bw, bh)), Draw->GREY1, 0, 0);
		if(tmpm == nil)
			return;
	}
	# Source pixels
	sbpl := (iw * img.depth + 7) / 8;
	src := array[sbpl * ih] of byte;
	if(img.readpixels(img.r, src) < 0)
		return;
	mbpl := 0;
	msrc: array of byte = nil;
	if(mask != nil){
		mbpl = (iw * mask.depth + 7) / 8;
		msrc = array[mbpl * ih] of byte;
		if(mask.readpixels(mask.r, msrc) < 0)
			return;
	}
	dbpl := (bw * img.depth + 7) / 8;
	dstb := array[dbpl * bh] of { * => byte 0 };
	dmpl := (bw + 7) / 8;
	dmsk := array[dmpl * bh] of { * => byte 0 };
	cx := real (bw - 1) / 2.0;
	cy := real (bh - 1) / 2.0;
	for(y := 0; y < bh; y++){
		for(x := 0; x < bw; x++){
			# inverse rotate into sprite local coords (-sw/2..sw/2)
			dx := real x - cx;
			dy := real y - cy;
			lx := dx * cs + dy * sn;
			ly := -dx * sn + dy * cs;
			if(lx < -hx || lx >= hx || ly < -hy || ly >= hy)
				continue;
			# map to source pixel
			u := int ((lx + hx) * real iw / real sw);
			v := int ((ly + hy) * real ih / real sh);
			if(u < 0 || u >= iw || v < 0 || v >= ih)
				continue;
			opaque := 1;
			if(msrc != nil){
				if(mask.depth == 1){
					bit := msrc[v * mbpl + (u >> 3)];
					opaque = (int bit & (16r80 >> (u & 7))) != 0;
				}else
					opaque = msrc[v * mbpl + u] != byte 0;
			}
			if(!opaque)
				continue;
			if(img.depth == 8)
				dstb[y * dbpl + x] = src[v * sbpl + u];
			else if(img.depth == 32){
				si := (v * sbpl) + u * 4;
				di := (y * dbpl) + x * 4;
				dstb[di] = src[si];
				dstb[di+1] = src[si+1];
				dstb[di+2] = src[si+2];
				dstb[di+3] = src[si+3];
			}else
				continue;
			if(tmpm != nil)
				dmsk[y * dmpl + (x >> 3)] |= byte (16r80 >> (x & 7));
		}
	}
	tmp.writepixels(tmp.r, dstb);
	if(tmpm != nil)
		tmpm.writepixels(tmpm.r, dmsk);
	dr := Rect((sp.x - bw/2, sp.y - bh/2), (sp.x - bw/2 + bw, sp.y - bh/2 + bh));
	dst.draw(dr, tmp, tmpm, Point(0, 0));
}

sprite3(c: ref Context, p: Vector, img, mask: ref Image, scale: real)
{
	spriteat(c, p, img, mask, scale, 0.0);
}

sprite3zb(c: ref Context, p: Vector, img, mask: ref Image, scale, degz: real)
{
	spriteat(c, p, img, mask, scale, degz);
}

sprite3yb(c: ref Context, p: Vector, img, mask: ref Image, scale: real)
{
	# Billboard facing camera: same as sprite3 for now (no yaw tilt).
	spriteat(c, p, img, mask, scale, 0.0);
}

sprite3mat(c: ref Context, p: Vector, m: Matrix, img, mask: ref Image, scale: real)
{
	# Apply object matrix then place at p.
	q := mulpoint(m, Vector(0.0, 0.0, 0.0));
	q.x += p.x; q.y += p.y; q.z += p.z;
	spriteat(c, q, img, mask, scale, 0.0);
}

vdot(a, b: Vector): real
{
	return a.x*b.x + a.y*b.y + a.z*b.z;
}

vcross(a, b: Vector): Vector
{
	return Vector(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}

vnorm(v: Vector): Vector
{
	d := math->sqrt(vdot(v, v));
	if(d == 0.0)
		return v;
	return Vector(v.x/d, v.y/d, v.z/d);
}
