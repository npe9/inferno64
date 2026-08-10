implement Draw3d;

# Draw3d via /dev/draw protocol letters (3/M/w/u/z/g/G/h/j/k).
# Falls back is the caller's job: load this module, or software draw3d.dis.
# Server projects geometry; Cocoa Metal batches g/G/k/h onto the drawable.

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

D3CapMatrix, D3CapFill, D3CapLine, D3CapPlot, D3CapSprite, D3CapEllipse: con 1<<iota;
D3CapGPU, D3CapReadback, D3CapNearClip, D3CapDepthOrder: con 1<<iota;
D3CapCore: con D3CapMatrix|D3CapFill|D3CapLine|D3CapPlot|D3CapSprite|D3CapEllipse;

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
	aw: array of Vector;	# world-space verts for protocol fill
	apn: int;
	ignore: int;
	cur: ref Context;
};

ms: Mstate;
inited := 0;
haveproto := 0;
protocaps := 0;
probed := 0;

# Cached protocol state — avoid re-sending M/w/u on every line3.
sync_ok := 0;
sync_mx, sync_cx, sync_my, sync_cy: real;
sync_zenable, sync_clipbehind: int;
sync_modl, sync_prjl: Matrix;	# last matrices sent (nil until first sync)

puti32(a: array of byte, o: int, v: int)
{
	a[o] = byte v;
	a[o+1] = byte (v>>8);
	a[o+2] = byte (v>>16);
	a[o+3] = byte (v>>24);
}

puti16(a: array of byte, o: int, v: int)
{
	a[o] = byte v;
	a[o+1] = byte (v>>8);
}

putf32(a: array of byte, o: int, x: real)
{
	puti32(a, o, math->realbits32(x));
}

putmat(a: array of byte, o: int, m: Matrix)
{
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++)
			putf32(a, o + (i*4+j)*4, m[i][j]);
}

writemsg(d: ref Display, msg: array of byte): int
{
	if(d == nil)
		return -1;
	return d.writedraw(msg);
}

probe(d: ref Display): int
{
	if(d == nil)
		return 0;
	ci := d.newimage(Rect((0, 0), (1, 1)), Draw->RGBA32, 0, 0);
	if(ci != nil){
		msg := array[5] of byte;
		msg[0] = byte 'C';
		puti32(msg, 1, ci.id());
		if(writemsg(d, msg) >= 0){
			buf := array[4] of byte;
			if(ci.readpixels(ci.r, buf) == 4)
				return int buf[0] | (int buf[1]<<8) | (int buf[2]<<16) | (int buf[3]<<24);
		}
	}
	# Compatibility with the first extension revision, which only had '3'.
	if(writemsg(d, array[] of {byte '3'}) >= 0)
		return D3CapCore;
	return 0;
}

mateq(a, b: Matrix): int
{
	if(a == nil || b == nil)
		return 0;
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++)
			if(a[i][j] != b[i][j])
				return 0;
	return 1;
}

matcopy(dst, src: Matrix)
{
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++)
			dst[i][j] = src[i][j];
}

ensuresyncmat()
{
	if(sync_modl == nil)
		sync_modl = newmatrix();
	if(sync_prjl == nil)
		sync_prjl = newmatrix();
}

sync3d(c: ref Context)
{
	i, j: int;
	e: real;

	if(c == nil || c.dst == nil || c.dst.display == nil || !haveproto)
		return;
	d := c.dst.display;
	ensuresyncmat();

	# Effective model on the wire: identity when Limbo settransform is active.
	model := hd ms.modl;
	useident := c.transform != nil;
	mod_same := sync_ok;
	if(useident){
		for(i = 0; mod_same && i < 4; i++)
			for(j = 0; mod_same && j < 4; j++){
				e = 0.0;
				if(i == j)
					e = 1.0;
				if(sync_modl[i][j] != e)
					mod_same = 0;
			}
	}else
		mod_same = sync_ok && mateq(sync_modl, model);
	prj_same := sync_ok && mateq(sync_prjl, hd ms.prjl);
	vp_same := sync_ok && sync_mx == c.mx && sync_cx == c.cx
		&& sync_my == c.my && sync_cy == c.cy;
	ze := c.zenable;
	cb := c.clipbehind;
	if(c.transform != nil)
		cb = 0;	# eye-space verts already clipped in toeye
	flg_same := sync_ok && sync_zenable == ze && sync_clipbehind == cb;

	if(!(mod_same && prj_same && vp_same && flg_same)){
		m := array[1+1+16*4] of byte;
		m[0] = byte 'M';
		if(!mod_same){
			m[1] = byte 0;
			if(useident){
				for(i = 0; i < 16; i++)
					putf32(m, 2 + i*4, 0.0);
				putf32(m, 2 + 0*4, 1.0);
				putf32(m, 2 + 5*4, 1.0);
				putf32(m, 2 + 10*4, 1.0);
				putf32(m, 2 + 15*4, 1.0);
				for(i = 0; i < 4; i++)
					for(j = 0; j < 4; j++){
						sync_modl[i][j] = 0.0;
						if(i == j)
							sync_modl[i][j] = 1.0;
					}
			}else{
				putmat(m, 2, model);
				matcopy(sync_modl, model);
			}
			writemsg(d, m);
		}
		if(!prj_same){
			m[1] = byte 1;
			putmat(m, 2, hd ms.prjl);
			writemsg(d, m);
			matcopy(sync_prjl, hd ms.prjl);
		}
		if(!vp_same){
			w := array[1+4*4] of byte;
			w[0] = byte 'w';
			putf32(w, 1, c.mx);
			putf32(w, 5, c.cx);
			putf32(w, 9, c.my);
			putf32(w, 13, c.cy);
			writemsg(d, w);
			sync_mx = c.mx;
			sync_cx = c.cx;
			sync_my = c.my;
			sync_cy = c.cy;
		}
		if(!flg_same){
			u := array[2] of byte;
			u[0] = byte 'u';
			u[1] = byte 0;
			if(ze)
				u[1] |= byte 1;
			if(cb)
				u[1] |= byte 2;
			writemsg(d, u);
			sync_zenable = ze;
			sync_clipbehind = cb;
		}
		sync_ok = 1;
	}
}

# World → protocol vertex: apply model (+ optional transform) when needed.
protovert(c: ref Context, v: Vector): (Vector, int)
{
	if(c.transform == nil)
		return (v, 1);
	return toeye(c, v);
}

init()
{
	if(inited)
		return;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	polyfill = load Polyfill Polyfill->PATH;
	if(polyfill == nil){
		sys->fprint(sys->fildes(2), "draw3ddev: cannot load polyfill: %r\n");
		raise "fail:load";
	}
	polyfill->init();
	inited = 1;
	# Probe requires a Display; deferred until first context().
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
	if(dst != nil && dst.display != nil && !probed){
		protocaps = probe(dst.display);
		haveproto = (protocaps & D3CapMatrix) != 0;
		probed = 1;
		if(!haveproto)
			sys->fprint(sys->fildes(2), "draw3ddev: no draw3d letters; software fallback\n");
	}
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
	if(c == nil)
		return;
	if(haveproto && (protocaps & D3CapDepthOrder) != 0 && c.dst != nil){
		sync3d(c);
		msg := array[1+4] of byte;
		msg[0] = byte 'z';
		puti32(msg, 1, c.dst.id());
		writemsg(c.dst.display, msg);
	}
	if(c.zstate != nil)
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
	ms.aw = array[nvert] of Vector;
	ms.apn = 0;
	matmul();
}

# Same model→transform→proj path as project; returns clip xy for circle sizing.
vertex(c: ref Context, x, y, z: real): (real, real)
{
	ms.cur = c;
	if(ms.apn < len ms.aw)
		ms.aw[ms.apn] = Vector(x, y, z);
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
	CIRCLE or FILLCIRCLE or ELLIPSE or FILLELLIPSE =>
		if(haveproto && (protocaps & D3CapEllipse) != 0 && ms.apn >= 1){
			(pv, ok) := protovert(c, ms.aw[0]);
			if(ok){
				sync3d(c);
				rx := real ms.vr;
				ry := real ms.vr;
				if(ms.vk == ELLIPSE || ms.vk == FILLELLIPSE)
					ry = real ms.vrr;
				fl := 0;
				if(ms.vk == FILLCIRCLE || ms.vk == FILLELLIPSE)
					fl = 1;
				msg := array[1+4+4+1+4+3*4+4+4] of byte;
				msg[0] = byte 'q';
				puti32(msg, 1, c.dst.id());
				puti32(msg, 5, vc.id());
				msg[9] = byte fl;
				puti32(msg, 10, 0);	# thick
				putf32(msg, 14, pv.x);
				putf32(msg, 18, pv.y);
				putf32(msg, 22, pv.z);
				putf32(msg, 26, rx);
				putf32(msg, 30, ry);
				writemsg(c.dst.display, msg);
				return;
			}
		}
		if(ms.vk == CIRCLE)
			dst.ellipse(ms.ap[0], ms.vr, ms.vr, 0, vc, Point(0, 0));
		else if(ms.vk == FILLCIRCLE)
			dst.fillellipse(ms.ap[0], ms.vr, ms.vr, vc, Point(0, 0));
		else if(ms.vk == ELLIPSE)
			dst.ellipse(ms.ap[0], ms.vr, ms.vrr, 0, vc, Point(0, 0));
		else
			dst.fillellipse(ms.ap[0], ms.vr, ms.vrr, vc, Point(0, 0));
	POLY =>
		# Outline via line3 segments on the protocol path.
		if(haveproto && (protocaps & D3CapLine) != 0 && ms.apn >= 2){
			for(i := 0; i < ms.apn; i++){
				j := i+1;
				if(j >= ms.apn)
					j = 0;
				line3(c, ms.aw[i], ms.aw[j], 0);
			}
		}else{
			ms.ap[len ms.ap - 1] = ms.ap[0];
			dst.poly(ms.ap, Draw->Endsquare, Draw->Endsquare, 0, vc, Point(0, 0));
		}
	FILLPOLY =>
		if(haveproto && (protocaps & D3CapFill) != 0 && ms.apn >= 3)
			fillpoly3(c, ms.aw[:ms.apn], Vector(0.0, 0.0, 1.0), 1.0);
		else{
			ms.ap[len ms.ap - 1] = ms.ap[0];
			dst.fillpoly(ms.ap, ~0, vc, Point(0, 0));
		}
	}
}

line3(c: ref Context, a, b: Vector, thick: int)
{
	if(c.dst == nil || c.colour == nil)
		return;
	if(thick < 0)
		thick = 0;
	if(haveproto && (protocaps & D3CapLine) != 0){
		(pa3, oka) := protovert(c, a);
		(pb3, okb) := protovert(c, b);
		if(!oka || !okb)
			return;
		sync3d(c);
		msg := array[1+4+4+4+6*4] of byte;
		msg[0] = byte 'G';
		puti32(msg, 1, c.dst.id());
		puti32(msg, 5, c.colour.id());
		puti32(msg, 9, thick);
		putf32(msg, 13, pa3.x);
		putf32(msg, 17, pa3.y);
		putf32(msg, 21, pa3.z);
		putf32(msg, 25, pb3.x);
		putf32(msg, 29, pb3.y);
		putf32(msg, 33, pb3.z);
		writemsg(c.dst.display, msg);
		return;
	}
	(pa, nil, oka) := project(c, a);
	(pb, nil, okb) := project(c, b);
	if(!oka || !okb)
		return;
	c.dst.line(pa, pb, Draw->Endsquare, Draw->Endsquare, thick, c.colour, Point(0, 0));
}

plot3(c: ref Context, v: Vector)
{
	if(c.dst == nil || c.colour == nil)
		return;
	if(haveproto && (protocaps & D3CapPlot) != 0){
		(pv, ok) := protovert(c, v);
		if(!ok)
			return;
		sync3d(c);
		msg := array[1+4+4+3*4] of byte;
		msg[0] = byte 'h';
		puti32(msg, 1, c.dst.id());
		puti32(msg, 5, c.colour.id());
		putf32(msg, 9, pv.x);
		putf32(msg, 13, pv.y);
		putf32(msg, 17, pv.z);
		writemsg(c.dst.display, msg);
		return;
	}
	(p, nil, ok) := project(c, v);
	if(!ok)
		return;
	c.dst.draw(Rect(p, p.add(Point(1, 1))), c.colour, nil, Point(0, 0));
}

# Soft fill with Polyfill z (matches draw3d.b) when protocol is unavailable.
softfillpoly3(c: ref Context, verts: array of Vector, normal: Vector, lit: real)
{
	n := len verts;
	ap := array[n + 1] of Point;
	for(i := 0; i < n; i++){
		(p, nil, ok) := project(c, verts[i]);
		if(!ok)
			return;
		ap[i] = p;
	}
	ap[n] = ap[0];
	col := litcolour(c, lit);
	if(c.zenable && c.zstate != nil && normal.z != 0.0){
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
			c.dst.fillpoly(ap, ~0, col, Point(0, 0));
			return;
		}
		a := -f.x / (cz * α);
		b := -f.y / (cz * γ);
		dd := d / cz - β * a - δ * b;
		if(a <= -LIMIT || a >= LIMIT || b <= -LIMIT || b >= LIMIT || dd <= -LIMIT || dd >= LIMIT){
			c.dst.fillpoly(ap, ~0, col, Point(0, 0));
			return;
		}
		dx := int (a * ZSCALE);
		dy := int (b * ZSCALE);
		dc := int (dd * ZSCALE);
		polyfill->fillpoly(c.dst, ap, ~0, col, Point(0, 0), c.zstate, dc, dx, dy);
	}else
		c.dst.fillpoly(ap, ~0, col, Point(0, 0));
}

# Tint solid 32-bit colour by lit (Metal / d3applylit parity). Non-solid pens unchanged.
lit_src: ref Image;
lit_out: ref Image;
lit_factor: real;

litcolour(c: ref Context, lit: real): ref Image
{
	if(c == nil || c.colour == nil || (lit >= 0.999 && lit <= 1.001))
		return c.colour;
	col := c.colour;
	if(col.depth != 32 || col.display == nil)
		return col;
	if(lit < 0.0)
		lit = 0.0;
	if(lit_src == col && lit_out != nil && lit_factor == lit)
		return lit_out;
	buf := array[4] of byte;
	r1 := Rect(col.r.min, col.r.min.add(Point(1, 1)));
	if(col.readpixels(r1, buf) < 0)
		return col;
	r := int (real buf[0] * lit);
	g := int (real buf[1] * lit);
	b := int (real buf[2] * lit);
	if(r > 255) r = 255;
	if(g > 255) g = 255;
	if(b > 255) b = 255;
	out := col.display.rgb(r, g, b);
	if(out == nil)
		return col;
	lit_src = col;
	lit_out = out;
	lit_factor = lit;
	return out;
}

fillpoly3(c: ref Context, verts: array of Vector, normal: Vector, lit: real)
{
	n := len verts;
	if(n < 3 || c.dst == nil || c.colour == nil)
		return;
	if(haveproto && (protocaps & D3CapFill) != 0){
		eye := array[n] of Vector;
		for(i := 0; i < n; i++){
			(e, ok) := protovert(c, verts[i]);
			if(!ok)
				return;
			eye[i] = e;
		}
		# Normal in the same space as protocol verts.
		nrm := normal;
		if(c.transform != nil){
			# Verts are eye-space (model applied in toeye); rotate normal by model only.
			o := mulpoint(hd ms.modl, Vector(0.0, 0.0, 0.0));
			n1 := mulpoint(hd ms.modl, normal);
			nrm = Vector(n1.x - o.x, n1.y - o.y, n1.z - o.z);
		}
		sync3d(c);
		msg := array[1+4+4+2 + 4*4 + n*12] of byte;
		msg[0] = byte 'k';
		puti32(msg, 1, c.dst.id());
		puti32(msg, 5, c.colour.id());
		puti16(msg, 9, n);
		putf32(msg, 11, nrm.x);
		putf32(msg, 15, nrm.y);
		putf32(msg, 19, nrm.z);
		putf32(msg, 23, lit);
		for(i = 0; i < n; i++){
			putf32(msg, 27+i*12, eye[i].x);
			putf32(msg, 27+i*12+4, eye[i].y);
			putf32(msg, 27+i*12+8, eye[i].z);
		}
		writemsg(c.dst.display, msg);
		return;
	}
	softfillpoly3(c, verts, normal, lit);
}

spriteat(c: ref Context, p: Vector, img, mask: ref Image, scale: real, degz: real, flags: int)
{
	if(c.dst == nil || img == nil)
		return;
	# Normalize angle for zb
	adz := degz;
	while(adz >= 360.0)
		adz -= 360.0;
	while(adz < 0.0)
		adz += 360.0;
	if(haveproto && (protocaps & D3CapSprite) != 0){
		(pv, ok) := protovert(c, p);
		if(!ok)
			return;
		sync3d(c);
		fl := flags;
		mid := 0;
		if(mask != nil){
			fl |= 1;
			mid = mask.id();
		}
		n := 1+4+4+4+1+4+4+3*4;
		if(fl & 8)
			n += 16*4;
		msg := array[n] of byte;
		msg[0] = byte 'j';
		puti32(msg, 1, c.dst.id());
		puti32(msg, 5, img.id());
		puti32(msg, 9, mid);
		msg[13] = byte fl;
		putf32(msg, 14, scale);
		putf32(msg, 18, adz);
		putf32(msg, 22, pv.x);
		putf32(msg, 26, pv.y);
		putf32(msg, 30, pv.z);
		writemsg(c.dst.display, msg);
		return;
	}
	(sp, ez, ok) := project(c, p);
	if(!ok)
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
	if(flags & 4)	# yb vertical squash
		sh = int (real sh * 0.85);
	if(sw < 1) sw = 1;
	if(sh < 1) sh = 1;
	needrot := (flags & 2) != 0 && !(adz < 0.5 || adz > 359.5);
	if(!needrot){
		r := Rect((sp.x - sw/2, sp.y - sh/2), (sp.x - sw/2 + sw, sp.y - sh/2 + sh));
		c.dst.draw(r, img, mask, img.r.min);
		return;
	}
	rotsprite(c.dst, sp, sw, sh, img, mask, adz);
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
	spriteat(c, p, img, mask, scale, 0.0, 0);
}

sprite3zb(c: ref Context, p: Vector, img, mask: ref Image, scale, degz: real)
{
	spriteat(c, p, img, mask, scale, degz, 2);
}

sprite3yb(c: ref Context, p: Vector, img, mask: ref Image, scale: real)
{
	# Billboard yaw stand-in: vertical squash via protocol flag bit2.
	spriteat(c, p, img, mask, scale, 0.0, 4);
}

sprite3mat(c: ref Context, p: Vector, m: Matrix, img, mask: ref Image, scale: real)
{
	# Apply object matrix then place at p (protocol 'j' bit3, or soft).
	q := mulpoint(m, Vector(0.0, 0.0, 0.0));
	q.x += p.x; q.y += p.y; q.z += p.z;
	if(haveproto && (protocaps & D3CapSprite) != 0){
		(pv, ok) := protovert(c, q);
		if(!ok || c.dst == nil || img == nil)
			return;
		sync3d(c);
		fl := 8;
		mid := 0;
		if(mask != nil){
			fl |= 1;
			mid = mask.id();
		}
		msg := array[1+4+4+4+1+4+4+3*4+16*4] of byte;
		msg[0] = byte 'j';
		puti32(msg, 1, c.dst.id());
		puti32(msg, 5, img.id());
		puti32(msg, 9, mid);
		msg[13] = byte fl;
		putf32(msg, 14, scale);
		putf32(msg, 18, 0.0);
		# Send original p; server applies mat then adds p — but we already
		# folded mat*0+p into q. Send identity mat + q as xyz.
		putf32(msg, 22, pv.x);
		putf32(msg, 26, pv.y);
		putf32(msg, 30, pv.z);
		for(i := 0; i < 16; i++)
			putf32(msg, 34+i*4, 0.0);
		putf32(msg, 34+0*4, 1.0);
		putf32(msg, 34+5*4, 1.0);
		putf32(msg, 34+10*4, 1.0);
		putf32(msg, 34+15*4, 1.0);
		writemsg(c.dst.display, msg);
		return;
	}
	spriteat(c, q, img, mask, scale, 0.0, 0);
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
