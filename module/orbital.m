# orbital - hydrogen wave functions, as functions of position
#
# psi_nlm(r,theta,phi) = R_nl(r) Y_lm(theta,phi), in atomic units with
# Z adjustable.  The angular part is the REAL form - the combinations of
# +m and -m that give the shapes with names, p_x and d_z2 and so on -
# because those are what anyone draws and what the sign of a lobe means
# anything for.  The complex Y_lm have constant modulus in phi and
# would render as featureless rings.
#
# This is a library and not part of the viewer so that orbitaltest(1)
# checks the same functions danby/orbital draws, rather than a second
# copy of the formulas that could drift from them.

Orbital: module
{
	PATH: con "/dis/lib/orbital.dis";

	init:	fn();

	# psi at a point.  n >= 1, 0 <= l < n, -l <= m <= l; z is the
	# charge.  Returns 0 for a combination that is not a state.
	psi:	fn(n, l, m: int, z, x, y, zc: real): real;

	# the pieces, for a caller that wants one without the other
	radial:	fn(n, l: int, z, r: real): real;
	angular: fn(l, m: int, x, y, zc: real): real;

	# the largest |psi| on a grid of the given half-width, which is what
	# a picture needs to scale itself, and what a sampler needs for a
	# threshold.  steps is per axis.
	peak:	fn(n, l, m: int, z, half: real, steps: int): real;

	# a sensible half-width to draw this state in: orbitals grow as
	# n^2/z, so one fixed box is wrong for every n but one.
	extent:	fn(n: int, z: real): real;
};
