implement Numerics;

include "numerics.m";

workspace(n: int): ref Workspace
{
	if(n < 0)
		n = 0;
	return ref Workspace(array[n] of real, array[n] of real,
		array[n] of real, array[n] of real, array[n] of real);
}

rk4(w: ref Workspace, rhs: Rhs, t, h: real, y: array of real)
{
	n := len y;
	if(w == nil || len w.k1 != n)
		raise "numerics: workspace dimension mismatch";
	if(rhs == nil)
		raise "numerics: nil right hand side";

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
