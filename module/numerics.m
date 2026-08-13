Numerics: module
{
	PATH:	con "/dis/lib/numerics.dis";

	# Right hand side of an explicit first-order initial-value problem.
	# Implementations write dy/dt into dy.  The arrays have equal length.
	Rhs: type ref fn(t: real, y, dy: array of real);

	# Reusable storage for integration.  A Workspace is tied only to the
	# dimension of the vector, never to a particular physical model.
	Workspace: adt {
		k1, k2, k3, k4, k5, k6: array of real;
		work, trial, error: array of real;
	};

	Tolerance: adt {
		absolute, relative: real;
		hmin, hmax: real;
	};

	Stepresult: adt {
		t, hnext, error: real;
		accepted, evaluations: int;
	};

	workspace:	fn(n: int): ref Workspace;
	euler:		fn(w: ref Workspace, rhs: Rhs, t, h: real,
			y: array of real);
	heun:		fn(w: ref Workspace, rhs: Rhs, t, h: real,
			y: array of real);
	rk4:		fn(w: ref Workspace, rhs: Rhs, t, h: real, y: array of real);
	rkf45:		fn(w: ref Workspace, rhs: Rhs, tolerance: Tolerance,
			t, h: real, y: array of real): Stepresult;
	adaptive:	fn(w: ref Workspace, rhs: Rhs, tolerance: Tolerance,
			t0, t1, h: real, y: array of real): Stepresult;
	integrate:	fn(w: ref Workspace, rhs: Rhs, t0, t1, hmax: real,
			y: array of real): real;
};
