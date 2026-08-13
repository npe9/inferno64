implement Ode;

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "ode.m";

init()
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
}

new(): ref ODE
{
	if(sys == nil)
		init();
	return ref ODE(
		nil, nil,
		0.0, 0.002, 0.00001,	# drag_v, drag_v2, drag_v3 (MassSpring defaults)
		5000.0,			# accel_limit
		0.0,			# t
		1.0,			# t_scale
		0,			# paused
		0.01			# h
	);
}

del(ode: ref ODE)
{
	ode.masses = nil;
	ode.springs = nil;
}

addmass(ode: ref ODE, m: ref Mass)
{
	if(m.mass <= 0.0)
		m.mass = 1.0;
	ode.masses = m :: ode.masses;
}

addspring(ode: ref ODE, s: ref Spring)
{
	ode.springs = s :: ode.springs;
}

remmass(ode: ref ODE, m: ref Mass)
{
	nl: list of ref Mass;
	for(l := ode.masses; l != nil; l = tl l)
		if(hd l != m)
			nl = hd l :: nl;
	ode.masses = nl;
}

remspring(ode: ref ODE, s: ref Spring)
{
	nl: list of ref Spring;
	for(l := ode.springs; l != nil; l = tl l)
		if(hd l != s)
			nl = hd l :: nl;
	ode.springs = nl;
}

pause(ode: ref ODE, on: int)
{
	ode.paused = on;
}

clearforces(ode: ref ODE)
{
	for(l := ode.masses; l != nil; l = tl l){
		m := hd l;
		m.fx = m.fy = m.fz = 0.0;
	}
}

renum(ode: ref ODE)
{
	i := 0;
	for(lm := ode.masses; lm != nil; lm = tl lm){
		(hd lm).num = i;
		i++;
	}
	i = 0;
	for(ls := ode.springs; ls != nil; ls = tl ls){
		s := hd ls;
		s.num = i;
		i++;
	}
}

massfind(ode: ref ODE, x, y, z: real): ref Mass
{
	best: ref Mass;
	bestd := 1e300;
	for(l := ode.masses; l != nil; l = tl l){
		m := hd l;
		if(m.flags & Ode->MSF_INACTIVE)
			continue;
		d := d3normsqr(d3sub(d3(x,y,z), d3(m.x,m.y,m.z)));
		if(d < bestd){
			bestd = d;
			best = m;
		}
	}
	return best;
}

# Snapshot of state for RK4
St: adt {
	x, y, z, vx, vy, vz: real;
};

update(ode: ref ODE, dt: real)
{
	if(ode.paused || dt <= 0.0)
		return;
	dt *= ode.t_scale;

	# Save app forces — they apply each sub-evaluation
	nf := 0;
	for(lm := ode.masses; lm != nil; lm = tl lm)
		nf++;
	afx := array[nf] of real;
	afy := array[nf] of real;
	afz := array[nf] of real;
	i := 0;
	for(lm = ode.masses; lm != nil; lm = tl lm){
		m := hd lm;
		afx[i] = m.fx;
		afy[i] = m.fy;
		afz[i] = m.fz;
		i++;
	}

	# RK4 with fixed step; subdivide large dt
	h := ode.h;
	if(h <= 0.0)
		h = 0.01;
	left := dt;
	while(left > 1e-12){
		step := h;
		if(step > left)
			step = left;
		rk4(ode, step, afx, afy, afz);
		left -= step;
		ode.t += step;
	}

	# leave fx as app last set (not cleared) — apps should clearforces each frame
}

rk4(ode: ref ODE, h: real, afx, afy, afz: array of real)
{
	n := 0;
	lm: list of ref Mass;
	for(lm = ode.masses; lm != nil; lm = tl lm)
		n++;
	if(n == 0)
		return;

	s0 := savestate(ode, n);
	a1 := accel(ode, afx, afy, afz, n);

	# k2 at s0 + h/2 * v/a from k1
	applyhalf(ode, s0, a1, h, 0.5);
	a2 := accel(ode, afx, afy, afz, n);

	restore(ode, s0);
	applyhalf(ode, s0, a2, h, 0.5);
	a3 := accel(ode, afx, afy, afz, n);

	restore(ode, s0);
	applyhalf(ode, s0, a3, h, 1.0);
	a4 := accel(ode, afx, afy, afz, n);

	restore(ode, s0);
	i := 0;
	for(lm = ode.masses; lm != nil; lm = tl lm){
		m := hd lm;
		if(m.flags & (Ode->MSF_INACTIVE|Ode->MSF_FIXED)){
			i++;
			continue;
		}
		# (.vx,.vy,.vz)=accel, (.x,.y,.z)=velocity — see accel()
		ax := (a1[i].vx + 2.0*a2[i].vx + 2.0*a3[i].vx + a4[i].vx) / 6.0;
		ay := (a1[i].vy + 2.0*a2[i].vy + 2.0*a3[i].vy + a4[i].vy) / 6.0;
		az := (a1[i].vz + 2.0*a2[i].vz + 2.0*a3[i].vz + a4[i].vz) / 6.0;
		vx := (a1[i].x + 2.0*a2[i].x + 2.0*a3[i].x + a4[i].x) / 6.0;
		vy := (a1[i].y + 2.0*a2[i].y + 2.0*a3[i].y + a4[i].y) / 6.0;
		vz := (a1[i].z + 2.0*a2[i].z + 2.0*a3[i].z + a4[i].z) / 6.0;
		m.x += h * vx;
		m.y += h * vy;
		m.z += h * vz;
		m.vx += h * ax;
		m.vy += h * ay;
		m.vz += h * az;
		i++;
	}
}

# Store derivatives in St: (.x,.y,.z)=velocity, (.vx,.vy,.vz)=acceleration
accel(ode: ref ODE, afx, afy, afz: array of real, n: int): array of St
{
	out := array[n] of St;

	# restore app forces for this evaluation
	i := 0;
	lm: list of ref Mass;
	for(lm = ode.masses; lm != nil; lm = tl lm){
		m := hd lm;
		m.fx = afx[i];
		m.fy = afy[i];
		m.fz = afz[i];
		i++;
	}

	springs(ode);
	drag(ode);

	i = 0;
	for(lm = ode.masses; lm != nil; lm = tl lm){
		m := hd lm;
		out[i].x = m.vx;
		out[i].y = m.vy;
		out[i].z = m.vz;
		if(m.flags & (Ode->MSF_INACTIVE|Ode->MSF_FIXED) || m.mass <= 0.0){
			out[i].vx = out[i].vy = out[i].vz = 0.0;
			m.vx = m.vy = m.vz = 0.0;
		}else{
			ax := m.fx / m.mass;
			ay := m.fy / m.mass;
			az := m.fz / m.mass;
			if(ode.accel_limit > 0.0){
				mag := math->sqrt(ax*ax + ay*ay + az*az);
				if(mag > ode.accel_limit){
					s := ode.accel_limit / mag;
					ax *= s; ay *= s; az *= s;
				}
			}
			out[i].vx = ax;
			out[i].vy = ay;
			out[i].vz = az;
		}
		i++;
	}
	return out;
}

savestate(ode: ref ODE, n: int): array of St
{
	s := array[n] of St;
	i := 0;
	for(l := ode.masses; l != nil; l = tl l){
		m := hd l;
		s[i] = St(m.x, m.y, m.z, m.vx, m.vy, m.vz);
		i++;
	}
	return s;
}

restore(ode: ref ODE, s: array of St)
{
	i := 0;
	for(l := ode.masses; l != nil; l = tl l){
		m := hd l;
		m.x = s[i].x; m.y = s[i].y; m.z = s[i].z;
		m.vx = s[i].vx; m.vy = s[i].vy; m.vz = s[i].vz;
		i++;
	}
}

applyhalf(ode: ref ODE, s0: array of St, deriv: array of St, h, frac: real)
{
	i := 0;
	hh := h * frac;
	for(l := ode.masses; l != nil; l = tl l){
		m := hd l;
		if(!(m.flags & (Ode->MSF_INACTIVE|Ode->MSF_FIXED))){
			m.x = s0[i].x + hh * deriv[i].x;
			m.y = s0[i].y + hh * deriv[i].y;
			m.z = s0[i].z + hh * deriv[i].z;
			m.vx = s0[i].vx + hh * deriv[i].vx;
			m.vy = s0[i].vy + hh * deriv[i].vy;
			m.vz = s0[i].vz + hh * deriv[i].vz;
		}
		i++;
	}
}

springs(ode: ref ODE)
{
	for(l := ode.springs; l != nil; l = tl l){
		s := hd l;
		if(s.flags & Ode->SSF_INACTIVE || s.end1 == nil || s.end2 == nil){
			s.f = 0.0;
			s.displacement = 0.0;
			continue;
		}
		e1 := s.end1;
		e2 := s.end2;
		dx := e2.x - e1.x;
		dy := e2.y - e1.y;
		dz := e2.z - e1.z;
		d := math->sqrt(dx*dx + dy*dy + dz*dz);
		s.displacement = d - s.restlen;
		s.f = s.displacement * s.const;
		if(s.f > 0.0 && (s.flags & Ode->SSF_NO_TENSION))
			s.f = 0.0;
		else if(s.f < 0.0 && (s.flags & Ode->SSF_NO_COMPRESSION))
			s.f = 0.0;
		if(d > 0.0){
			scale := s.f / d;
			fx := dx * scale;
			fy := dy * scale;
			fz := dz * scale;
			e1.fx += fx; e1.fy += fy; e1.fz += fz;
			e2.fx -= fx; e2.fy -= fy; e2.fz -= fz;
		}
	}
}

drag(ode: ref ODE)
{
	if(ode.drag_v == 0.0 && ode.drag_v2 == 0.0 && ode.drag_v3 == 0.0)
		return;
	for(l := ode.masses; l != nil; l = tl l){
		m := hd l;
		if((m.flags & Ode->MSF_INACTIVE) || m.drag == 0.0)
			continue;
		dd := m.vx*m.vx + m.vy*m.vy + m.vz*m.vz;
		if(dd == 0.0)
			continue;
		d := ode.drag_v;
		if(ode.drag_v2 != 0.0)
			d += ode.drag_v2 * math->sqrt(dd);
		if(ode.drag_v3 != 0.0)
			d += ode.drag_v3 * dd;
		d *= m.drag;
		m.fx -= d * m.vx;
		m.fy -= d * m.vy;
		m.fz -= d * m.vz;
	}
}

d3(x, y, z: real): D3
{
	return D3(x, y, z);
}

d3add(a, b: D3): D3
{
	return D3(a.x+b.x, a.y+b.y, a.z+b.z);
}

d3sub(a, b: D3): D3
{
	return D3(a.x-b.x, a.y-b.y, a.z-b.z);
}

d3mul(s: real, a: D3): D3
{
	return D3(s*a.x, s*a.y, s*a.z);
}

d3dot(a, b: D3): real
{
	return a.x*b.x + a.y*b.y + a.z*b.z;
}

d3normsqr(a: D3): real
{
	return a.x*a.x + a.y*a.y + a.z*a.z;
}

d3norm(a: D3): real
{
	return math->sqrt(d3normsqr(a));
}

d3dist(a, b: D3): real
{
	return d3norm(d3sub(a, b));
}

d3unit(a: D3): D3
{
	n := d3norm(a);
	if(n == 0.0)
		return D3(0.0, 0.0, 0.0);
	return d3mul(1.0/n, a);
}
