Ode: module
{
	PATH:	con "/dis/lib/ode.dis";

	# Mass flags
	MSF_INACTIVE, MSF_FIXED: con 1 << iota;
	# Spring flags
	SSF_INACTIVE, SSF_NO_COMPRESSION, SSF_NO_TENSION: con 1 << iota;

	D3: adt {
		x, y, z:	real;
	};

	Mass: adt {
		x, y, z:		real;	# position
		vx, vy, vz:		real;	# velocity
		fx, fy, fz:		real;	# app force accumulators (cleared by update)
		mass:			real;
		drag:			real;	# drag_profile_factor
		flags:			int;
		num:			int;
		radius:			real;	# convenience for collision apps
		userdata:		int;
	};

	Spring: adt {
		end1, end2:		ref Mass;
		const:			real;	# Hooke constant
		restlen:		real;
		f:			real;	# set by update
		displacement:		real;	# set by update
		flags:			int;
		num:			int;
		userdata:		int;
	};

	ODE: adt {
		masses:			list of ref Mass;
		springs:		list of ref Spring;
		drag_v, drag_v2, drag_v3:	real;
		accel_limit:		real;
		t:			real;
		t_scale:		real;
		paused:			int;
		h:			real;	# integrator step hint
	};

	init:		fn();
	new:		fn(): ref ODE;
	del:		fn(ode: ref ODE);

	addmass:	fn(ode: ref ODE, m: ref Mass);
	addspring:	fn(ode: ref ODE, s: ref Spring);
	remmass:	fn(ode: ref ODE, m: ref Mass);
	remspring:	fn(ode: ref ODE, s: ref Spring);

	# zero mass.fx/fy/fz, advance by dt (wall seconds * t_scale).
	# Pipeline: springs → drag → app forces → F/m → accel clip → RK4.
	# Set mass forces before calling, or use the forces-already-in-fx convention:
	# update clears fx after reading them each substep via internal copy — see note in ode.b.
	# Simpler contract: call clearforces, accumulate into fx, then update.
	clearforces:	fn(ode: ref ODE);
	update:		fn(ode: ref ODE, dt: real);

	pause:		fn(ode: ref ODE, on: int);
	renum:		fn(ode: ref ODE);
	massfind:	fn(ode: ref ODE, x, y, z: real): ref Mass;

	# CD3 helpers
	d3:		fn(x, y, z: real): D3;
	d3add:		fn(a, b: D3): D3;
	d3sub:		fn(a, b: D3): D3;
	d3mul:		fn(s: real, a: D3): D3;
	d3dot:		fn(a, b: D3): real;
	d3norm:		fn(a: D3): real;
	d3normsqr:	fn(a: D3): real;
	d3dist:		fn(a, b: D3): real;
	d3unit:		fn(a: D3): D3;
};
