Numerics: module
{
	PATH:	con "/dis/lib/numerics.dis";

	# Right hand side of an explicit first-order initial-value problem.
	# Implementations write dy/dt into dy.  The arrays have equal length.
	Rhs: type ref fn(t: real, y, dy: array of real);

	# Reusable storage for integration.  A Workspace is tied only to the
	# dimension of the vector, never to a particular physical model.
	Workspace: adt {
		k1, k2, k3, k4, work: array of real;
	};

	workspace:	fn(n: int): ref Workspace;
	rk4:		fn(w: ref Workspace, rhs: Rhs, t, h: real, y: array of real);
	integrate:	fn(w: ref Workspace, rhs: Rhs, t0, t1, hmax: real,
			y: array of real): real;
};
