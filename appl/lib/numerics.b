implement Numerics;

include "math.m";
	math: Math;
include "numerics.m";

workspace(n: int): ref Workspace
{
	if(n < 0)
		n = 0;
	if(math == nil)
		math = load Math Math->PATH;
	return ref Workspace(
		array[n] of real,
		array[n] of real,
		array[n] of real,
		array[n] of real,
		array[n] of real,
		array[n] of real,
		array[n] of real,
		array[n] of real,
		array[n] of real);
}

check(w: ref Workspace, rhs: Rhs, n: int)
{
	if(w == nil || len w.k1 != n)
		raise "numerics: workspace dimension mismatch";
	if(rhs == nil)
		raise "numerics: nil right hand side";
}

euler(w: ref Workspace, rhs: Rhs, t, h: real, y: array of real)
{
	check(w,rhs,len y);
	rhs(t,y,w.k1);
	for(i := 0; i < len y; i++)
		y[i] += h*w.k1[i];
}

heun(w: ref Workspace, rhs: Rhs, t, h: real, y: array of real)
{
	check(w,rhs,len y);
	rhs(t,y,w.k1);
	for(i := 0; i < len y; i++)
		w.work[i] = y[i]+h*w.k1[i];
	rhs(t+h,w.work,w.k2);
	for(i = 0; i < len y; i++)
		y[i] += h*(w.k1[i]+w.k2[i])/2.0;
}

rk4(w: ref Workspace, rhs: Rhs, t, h: real, y: array of real)
{
	n := len y;
	check(w,rhs,n);

	rhs(t, y, w.k1);
	for(i := 0; i < n; i++)
		w.work[i] = y[i] + h*w.k1[i]/2.0;
	rhs(t+h/2.0, w.work, w.k2);
	for(i = 0; i < n; i++)
		w.work[i] = y[i] + h*w.k2[i]/2.0;
	rhs(t+h/2.0, w.work, w.k3);
	for(i = 0; i < n; i++)
		w.work[i] = y[i] + h*w.k3[i];
	rhs(t+h, w.work, w.k4);
	for(i = 0; i < n; i++)
		y[i] += h*(w.k1[i]+2.0*w.k2[i]+2.0*w.k3[i]+w.k4[i])/6.0;
}

rkf45(w: ref Workspace, rhs: Rhs, tolerance: Tolerance,
		t, h: real, y: array of real): Stepresult
{
	n := len y;
	check(w,rhs,n);
	if(math == nil)
		math = load Math Math->PATH;
	if(tolerance.absolute <= 0.0 || tolerance.relative < 0.0)
		raise "numerics: invalid tolerance";
	if(tolerance.hmin <= 0.0 || tolerance.hmax < tolerance.hmin)
		raise "numerics: invalid step bounds";

	rhs(t,y,w.k1);
	for(i := 0; i < n; i++)
		w.work[i] = y[i]+h*w.k1[i]/4.0;
	rhs(t+h/4.0,w.work,w.k2);
	for(i = 0; i < n; i++)
		w.work[i] = y[i]+h*(3.0*w.k1[i]+9.0*w.k2[i])/32.0;
	rhs(t+3.0*h/8.0,w.work,w.k3);
	for(i = 0; i < n; i++)
		w.work[i] = y[i]+h*(1932.0*w.k1[i]-7200.0*w.k2[i]
			+7296.0*w.k3[i])/2197.0;
	rhs(t+12.0*h/13.0,w.work,w.k4);
	for(i = 0; i < n; i++)
		w.work[i] = y[i]+h*(439.0*w.k1[i]/216.0-8.0*w.k2[i]
			+3680.0*w.k3[i]/513.0-845.0*w.k4[i]/4104.0);
	rhs(t+h,w.work,w.k5);
	for(i = 0; i < n; i++)
		w.work[i] = y[i]+h*(-8.0*w.k1[i]/27.0+2.0*w.k2[i]
			-3544.0*w.k3[i]/2565.0+1859.0*w.k4[i]/4104.0
			-11.0*w.k5[i]/40.0);
	rhs(t+h/2.0,w.work,w.k6);

	errmax := 0.0;
	for(i = 0; i < n; i++){
		fourth := y[i]+h*(25.0*w.k1[i]/216.0
			+1408.0*w.k3[i]/2565.0+2197.0*w.k4[i]/4104.0
			-w.k5[i]/5.0);
		w.trial[i] = y[i]+h*(16.0*w.k1[i]/135.0
			+6656.0*w.k3[i]/12825.0+28561.0*w.k4[i]/56430.0
			-9.0*w.k5[i]/50.0+2.0*w.k6[i]/55.0);
		w.error[i] = w.trial[i]-fourth;
		scale := tolerance.absolute+tolerance.relative*maxabs(y[i],w.trial[i]);
		ratio := abs(w.error[i])/scale;
		if(ratio > errmax)
			errmax = ratio;
	}
	accepted := errmax <= 1.0;
	if(accepted)
		for(i = 0; i < n; i++)
			y[i] = w.trial[i];
	factor := 5.0;
	if(errmax > 0.0)
		factor = 0.9*math->pow(errmax,-0.2);
	if(factor < 0.2)
		factor = 0.2;
	if(factor > 5.0)
		factor = 5.0;
	hnext := abs(h)*factor;
	if(hnext < tolerance.hmin)
		hnext = tolerance.hmin;
	if(hnext > tolerance.hmax)
		hnext = tolerance.hmax;
	if(h < 0.0)
		hnext = -hnext;
	tnext := t;
	if(accepted)
		tnext += h;
	return Stepresult(tnext,hnext,errmax,accepted,6);
}

adaptive(w: ref Workspace, rhs: Rhs, tolerance: Tolerance,
		t0, t1, h: real, y: array of real): Stepresult
{
	direction := 1.0;
	if(t1 < t0)
		direction = -1.0;
	h = abs(h)*direction;
	if(h == 0.0)
		h = tolerance.hmin*direction;
	t := t0;
	evaluations := 0;
	last := Stepresult(t,h,0.0,1,0);
	while((t1-t)*direction > 0.0){
		if((t+h-t1)*direction > 0.0)
			h = t1-t;
		last = rkf45(w,rhs,tolerance,t,h,y);
		evaluations += last.evaluations;
		if(last.accepted)
			t = last.t;
		else if(abs(h) <= tolerance.hmin)
			raise "numerics: tolerance unattainable at minimum step";
		h = last.hnext;
	}
	last.t = t;
	last.hnext = h;
	last.evaluations = evaluations;
	return last;
}

abs(v: real): real
{
	if(v < 0.0)
		return -v;
	return v;
}

maxabs(a, b: real): real
{
	a = abs(a);
	b = abs(b);
	if(a > b)
		return a;
	return b;
}

integrate(w: ref Workspace, rhs: Rhs, t0, t1, hmax: real,
		y: array of real): real
{
	if(hmax <= 0.0)
		raise "numerics: non-positive step bound";
	dir := 1.0;
	if(t1 < t0)
		dir = -1.0;
	t := t0;
	while((t1-t)*dir > 0.0){
		h := hmax*dir;
		if((t+h-t1)*dir > 0.0)
			h = t1-t;
		rk4(w, rhs, t, h, y);
		t += h;
	}
	return t;
}
