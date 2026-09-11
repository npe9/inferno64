# Two slits, and the time-dependent Schrodinger equation through them.
#
# psi = u + iv in atomic units, so
#
#	du/dt = -(1/2) lap v + V u's partner
#	dv/dt = +(1/2) lap u - V u
#
# and V is a wall at x = xw, of half-thickness th, with two gaps in it.
# The gaps are what makes this the double slit rather than a barrier:
#
#	open = step(sw - |y - ya|) + step(sw - |y - yb|)
#
# is 1 inside either slit and 0 elsewhere - the two never overlap - so
# the wall is v0 wherever it is wall and nothing wherever it is slit.
#
# `stagger' is not optional.  The eigenvalues of this system are purely
# imaginary, so advancing both fields from the same old values
# multiplies every mode by sqrt(1+(lambda h)^2) at EVERY step, whatever
# h is.  Staggered, the same explicit formula is symplectic.
#
# The wall is 90 and not 30 because a wall is only a wall if the
# packet cannot get through it: at 30, against an energy of 18 and a
# thickness of 0.5, about three per cent tunnels through EVERYWHERE
# along it, and since the packet is broad that leak is comparable to
# what goes through the slits.  The pattern then carries the packet's
# own shape rather than the slits', which looks like interference and
# is not.  Measured: with one slit open at v0=30 there were two lobes,
# at v0=90 there is one, where the open slit is.
#
# danby/slits overrides v0, the slit separation and the slit width from
# its own controls, so the numbers below are only where it starts.

mesh 240x192 domain 24.0x19.2 bc clamp
equation hoc u v
stagger
substeps 4
param v0 90.0
param xw 9.0
param th 0.25
param ya 11.4
param yb 7.8
param sw 0.5
rhs u u+h*(-0.5*lap_v + v0*step(th-abs(x-xw))*(1.0-(step(sw-abs(y-ya))+step(sw-abs(y-yb))))*v)
rhs v v+h*( 0.5*lap_u - v0*step(th-abs(x-xw))*(1.0-(step(sw-abs(y-ya))+step(sw-abs(y-yb))))*u)
time step 0.01
