implement Pde;

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "pde.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(math == nil)
		math = load Math Math->PATH;
}

new(nx, ny: int, dx, dy: real, bc: int): ref Field
{
	init();
	if(nx < 2) nx = 2;
	if(ny < 2) ny = 2;
	if(dx <= 0.0) dx = 1.0;
	if(dy <= 0.0) dy = 1.0;
	n := nx*ny;
	return ref Field(nx, ny, dx, dy, bc,
		array[n] of { * => 0.0 }, array[n] of { * => 0.0 }, array[n] of { * => 0.0 });
}

clear(f: ref Field, value: real)
{
	for(i := 0; i < len f.u; i++){
		f.u[i] = value;
		f.work[i] = value;
		f.old[i] = value;
	}
}

get(f: ref Field, x, y: int): real
{
	if(f.bc == PERIODIC){
		x = (x%f.nx + f.nx)%f.nx;
		y = (y%f.ny + f.ny)%f.ny;
	}else if(x < 0 || x >= f.nx || y < 0 || y >= f.ny){
		if(f.bc == ZERO)
			return 0.0;
		if(x < 0) x = 0;
		if(x >= f.nx) x = f.nx-1;
		if(y < 0) y = 0;
		if(y >= f.ny) y = f.ny-1;
	}
	return f.u[y*f.nx+x];
}

set(f: ref Field, x, y: int, value: real)
{
	if(x >= 0 && x < f.nx && y >= 0 && y < f.ny)
		f.u[y*f.nx+x] = value;
}

splat(f: ref Field, cx, cy, radius: int, value: real)
{
	for(y := cy-radius; y <= cy+radius; y++)
		for(x := cx-radius; x <= cx+radius; x++){
			dx := x-cx; dy := y-cy;
			if(dx*dx+dy*dy <= radius*radius)
				set(f, x, y, value);
		}
}

splatold(f: ref Field, cx, cy, radius: int, value: real)
{
	for(y := cy-radius; y <= cy+radius; y++)
		for(x := cx-radius; x <= cx+radius; x++){
			dx := x-cx; dy := y-cy;
			if(x >= 0 && x < f.nx && y >= 0 && y < f.ny && dx*dx+dy*dy <= radius*radius)
				f.old[y*f.nx+x] = value;
		}
}

lap(f: ref Field, x, y: int): real
{
	c := get(f, x, y);
	return (get(f,x-1,y)-2.0*c+get(f,x+1,y))/(f.dx*f.dx)
		+ (get(f,x,y-1)-2.0*c+get(f,x,y+1))/(f.dy*f.dy);
}

swap(f: ref Field)
{
	t := f.u; f.u = f.work; f.work = t;
}

diffuse(f: ref Field, d, dt: real)
{
	if(d <= 0.0 || dt <= 0.0) return;
	h2 := f.dx*f.dx;
	if(f.dy*f.dy < h2) h2 = f.dy*f.dy;
	maxdt := 0.24*h2/d;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	for(s := 0; s < ns; s++){
		for(y := 0; y < f.ny; y++)
			for(x := 0; x < f.nx; x++)
				f.work[y*f.nx+x] = get(f,x,y)+h*d*lap(f,x,y);
		swap(f);
	}
}

wave(f: ref Field, speed, damping, dt: real)
{
	if(speed <= 0.0 || dt <= 0.0) return;
	hmin := f.dx;
	if(f.dy < hmin) hmin = f.dy;
	maxdt := 0.65*hmin/speed;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	for(s := 0; s < ns; s++){
		q := speed*speed*h*h;
		d := damping*h;
		for(y := 0; y < f.ny; y++)
			for(x := 0; x < f.nx; x++){
				i := y*f.nx+x;
				f.work[i] = (2.0-d)*f.u[i]-(1.0-d)*f.old[i]+q*lap(f,x,y);
			}
		t := f.old; f.old = f.u; f.u = f.work; f.work = t;
	}
}

gray(a, b: ref Field, da, db, feed, kill, dt: real)
{
	if(a.nx != b.nx || a.ny != b.ny || dt <= 0.0) return;
	h2 := a.dx*a.dx;
	if(a.dy*a.dy < h2) h2 = a.dy*a.dy;
	dmax := da; if(db > dmax) dmax = db;
	maxdt := dt;
	if(dmax > 0.0)
		maxdt = 0.20*h2/dmax;
	ns := int (dt/maxdt)+1;
	h := dt/real(ns);
	for(s := 0; s < ns; s++){
		for(y := 0; y < a.ny; y++)
			for(x := 0; x < a.nx; x++){
				i := y*a.nx+x;
				av := a.u[i]; bv := b.u[i]; ab2 := av*bv*bv;
				a.work[i] = av+h*(da*lap(a,x,y)-ab2+feed*(1.0-av));
				b.work[i] = bv+h*(db*lap(b,x,y)+ab2-(feed+kill)*bv);
				if(a.work[i] < 0.0) a.work[i] = 0.0;
				if(a.work[i] > 1.0) a.work[i] = 1.0;
				if(b.work[i] < 0.0) b.work[i] = 0.0;
				if(b.work[i] > 1.0) b.work[i] = 1.0;
			}
		swap(a); swap(b);
	}
}
