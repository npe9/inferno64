# The time-dependent Schrodinger equation, as a pde(2) problem.
#
# psi = u + iv, in atomic units, so
#
#	du/dt = -(1/2) v'' + V v
#	dv/dt = +(1/2) u'' - V u
#
# and V is a rectangular barrier of height v0 and width bw at xb.
#
# Two things here are load-bearing.
#
# `stagger' advances v using the u just computed rather than the u it
# started with.  The eigenvalues of this system are purely imaginary, so
# advancing both fields together multiplies every mode by
# sqrt(1+(lambda h)^2) at EVERY step, for any h however small - it is
# not a step-size problem and no substep count fixes it.  Staggered, the
# same explicit formula is symplectic and conserves the norm.
#
# The mesh is 384x2 and not 384x1 because pde(2) wants at least two rows
# each way.  The two rows are seeded identically and the boundary is
# clamped, so the y part of the Laplacian is exactly zero and this is
# honestly one-dimensional.
#
# danby/tdse overrides v0 and bw from its own sliders after loading
# this, so the values below are only what it starts at.

mesh 384x2 domain 19.2x0.1 bc clamp
equation hoc u v
stagger
substeps 40
param v0 10.0
param xb 11.52
param bw 0.6
rhs u u+h*(-0.5*lap_v + v0*step(bw/2.0-abs(x-xb))*v)
rhs v v+h*( 0.5*lap_u - v0*step(bw/2.0-abs(x-xb))*u)
time step 0.004
