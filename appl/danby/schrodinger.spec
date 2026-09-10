#!/dis/danby/model.dis
#
# danby/schrodinger - Schrodinger's equation for a particle in a well
#
# The whole model is the script below: its parameters and their ranges,
# the wave function and the equation that carries it outward, the points
# that draw it and the two quantities it plots.  danbylab(2) is a library
# this calls with that script - it owns the window, the integrator and the
# controls, and knows nothing about this model.
#
# The independent variable is POSITION, not time.  Danbylab's mechanism
# family marches a system forward in t with rk4 and plots two observables
# against t on a signed axis, which is exactly what shooting the
# time-independent Schrodinger equation outward from the centre of a
# symmetric well needs; nothing else in the library had both.  The graph's
# x axis therefore says "time" and means x, which the man page says too.
#
# In units where h-bar is 1,
#
#	psi'' = 2 m (V(x) - E) psi,	V(x) = k x^2 / 2 + lambda x^4
#
# and the march starts at x = 0, where a symmetric well's solutions are
# either even (psi = 1, psi' = 0) or odd (psi = 0, psi' = 1).  Only at an
# eigenvalue does the tail stay down; at any other energy the growing
# solution is present and psi runs away.  That is the whole exercise: turn
# the energy slider until the tail stops flying off.
#
family mechanism
title Schrodinger's equation for a particle in a well
param energy 0.5 -1.0 4.0
param stiffness 1.0 -4.0 4.0
param quartic 0.0 0.0 1.0
param mass 1.0 0.5 4.5
param parity 0.0 0.0 1.0
maxtime 5.0
# The sliders ARE the letters in the equation, and a model whose
# parameters are letters has to say which is which somewhere the
# reader is already looking.  danbylab draws these along the bottom
# of the diagram pane.  Tokenizing collapses runs of spaces, so
# these cannot be aligned into columns - punctuate instead.
caption psi'' = 2 m (V - E) psi, with V(x) = k x^2 / 2 + lambda x^4
caption sliders: E = energy, k = stiffness, lambda = quartic, m = mass
caption left: the well V(x), with E drawn across it. right: psi, psi^2
caption a bound particle has no path and does not move. it stands as a
caption wave, and psi^2 is where you would find it if you looked.
caption only some E keep psi finite out here: those are the levels.
caption the marker is the solver. parity: below 0.5 even, above odd.
eq potential 0.5 stiffness t t + quartic t sup 4
eq curvature 2.0 mass { potential - energy }
state psi 1.0 - step { parity - 0.5 }
state slope step { parity - 0.5 }
derivative psi slope
derivative slope curvature psi
# The well, drawn as a polyline sampled at four radii each side, and
# the level E across it.  Both are clamped into -1.5..4.5 so a steep
# well or an inverted one cannot drag the vertical scale off and
# squash the level flat against the floor; the shape inside the range
# is exact.  clamp(v) = v - (v-hi)step(v-hi) + (lo-v)step(lo-v).
eq hi 4.5
eq lo 0.0 - 1.5
eq v1 0.1953125 stiffness + 0.152587890625 quartic
eq v2 0.78125 stiffness + 2.44140625 quartic
eq v3 1.7578125 stiffness + 12.359619140625 quartic
eq v4 3.125 stiffness + 39.0625 quartic
eq v5 4.8828125 stiffness + 95.367431640625 quartic
eq v6 7.03125 stiffness + 197.75390625 quartic
eq v7 9.5703125 stiffness + 366.363525390625 quartic
eq v8 12.5 stiffness + 625 quartic
eq c1 v1 - { v1 - hi } step { v1 - hi } + { lo - v1 } step { lo - v1 }
eq c2 v2 - { v2 - hi } step { v2 - hi } + { lo - v2 } step { lo - v2 }
eq c3 v3 - { v3 - hi } step { v3 - hi } + { lo - v3 } step { lo - v3 }
eq c4 v4 - { v4 - hi } step { v4 - hi } + { lo - v4 } step { lo - v4 }
eq c5 v5 - { v5 - hi } step { v5 - hi } + { lo - v5 } step { lo - v5 }
eq c6 v6 - { v6 - hi } step { v6 - hi } + { lo - v6 } step { lo - v6 }
eq c7 v7 - { v7 - hi } step { v7 - hi } + { lo - v7 } step { lo - v7 }
eq c8 v8 - { v8 - hi } step { v8 - hi } + { lo - v8 } step { lo - v8 }
point wl8 - 5 , c8
point wl7 - 4.375 , c7
point wl6 - 3.75 , c6
point wl5 - 3.125 , c5
point wl4 - 2.5 , c4
point wl3 - 1.875 , c3
point wl2 - 1.25 , c2
point wl1 - 0.625 , c1
point wc 0.0 , 0.0
point wr1 0.625 , c1
point wr2 1.25 , c2
point wr3 1.875 , c3
point wr4 2.5 , c4
point wr5 3.125 , c5
point wr6 3.75 , c6
point wr7 4.375 , c7
point wr8 5 , c8
point levelleft - 5.0 , energy
point levelright 5.0 , energy
point shot t , energy
link wl8 wl7 line
link wl7 wl6 line
link wl6 wl5 line
link wl5 wl4 line
link wl4 wl3 line
link wl3 wl2 line
link wl2 wl1 line
link wl1 wc line
link wc wr1 line
link wr1 wr2 line
link wr2 wr3 line
link wr3 wr4 line
link wr4 wr5 line
link wr5 wr6 line
link wr6 wr7 line
link wr7 wr8 line
link levelleft levelright accent
plain wc wl8 wl7 wl6 wl5 wl4 wl3 wl2 wl1 wr1 wr2 wr3 wr4 wr5 wr6 wr7 wr8 levelleft levelright
observable amplitude psi
observable probability psi psi
# the area under psi^2 IS the probability, so draw it as an area
shade probability
