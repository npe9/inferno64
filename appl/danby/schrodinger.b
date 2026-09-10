implement Schrodinger;

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

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Schrodinger: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Every slider range here is chosen so the slider can LAND on the values
# that matter.  danbylab gives a parameter 200 positions across its range
# and libtk snaps a scale to a whole multiple of the resulting resolution
# (scale.c: v = (v/res)*res, in units of 1/10000, so the snap is exact),
# which is a multiple of (max-min)/200 counted from zero, not from min.
# Energy -1..4 gives 0.025, and the harmonic oscillator's own eigenvalues
# 0.5, 1.5, 2.5 and 3.5 are all multiples of that; mass 0.5..4.5 gives
# 0.02, and 1.0 is a multiple of that.  An energy knob that could not
# reach an eigenvalue would make every run diverge and the model would be
# showing nothing.  The range reaches below zero because the double well
# the stiffness slider bends this into has its states there.
#
# The far wall is at x = 5, and both directions from there are worse.
# Nearer, the upper levels stop being distinguishable: at x = 4 one
# slider notch off E = 3.5 changes the tail by a factor of 17, which is
# not a signal, where at x = 5 it is a factor of 22000.  Further, the
# shooting itself comes apart - the growing solution is the stable one
# out here, so roundoff feeds it, and by x = 6 the computed tail at an
# exact eigenvalue is 2165 times the analytic wave function rather than
# the 1.02 times it still is at x = 5.  Past x = 6 the contrast between
# a right energy and a wrong one stops improving at all (7e9 at x = 6, 7,
# 8 and 9 alike), because both ends of it are then the same roundoff.
# All of those numbers are measured, not estimated.
#
# The well is symmetric and the march only ever goes one way, out from
# the centre - that is the whole point of splitting the solutions into
# even and odd, and it halves the work.  But the WELL has two sides, and
# a picture that draws only the half being integrated is drawing half a
# well.  So the diagram mirrors it: psi(-x) is psi(x) for an even state
# and -psi(x) for an odd one, which is exactly what `eq mirror' is, and
# the reflected marker and its rod come for free from the same state.
# Nothing extra is integrated.
#
# The fixed points are what makes the diagram a picture rather than a
# smear.  drawmechanism() scales the pane to the bounding
# box of the points, so a model whose only points are the moving ones
# scales the view to the thing it is drawing, and the thing it is
# drawing then never appears to move: the first version of this had
# origin, (t,0) and (t,psi) and nothing else, and the bob sat at 0.885
# of the pane width from t=1 to the end of the run, because the box's
# right edge WAS the bob.  origin/wall pin the horizontal extent to the
# whole march and ceiling/floor pin the vertical one to psi = +-1, so
# the foot now crosses the pane as the march goes out and the rod
# standing on it is the amplitude to a scale that holds still.  A psi
# bigger than 1 grows the box, which is how the picture says the tail
# has run away.
SPEC: con
	"family mechanism\n" +
	"title Schrodinger's equation for a particle in a well\n" +
	"param energy 0.5 -1.0 4.0\n" +
	"param stiffness 1.0 -4.0 4.0\n" +
	"param quartic 0.0 0.0 1.0\n" +
	"param mass 1.0 0.5 4.5\n" +
	"param parity 0.0 0.0 1.0\n" +
	"maxtime 5.0\n" +
	# The sliders ARE the letters in the equation, and a model whose
	# parameters are letters has to say which is which somewhere the
	# reader is already looking.  danbylab draws these along the bottom
	# of the diagram pane.  Tokenizing collapses runs of spaces, so
	# these cannot be aligned into columns - punctuate instead.
	"caption psi'' = 2 m (V - E) psi, with V(x) = k x^2 / 2 + lambda x^4\n" +
	"caption sliders: E = energy, k = stiffness, lambda = quartic, m = mass\n" +
	"caption left: the well V(x), with E drawn across it. right: psi, psi^2\n" +
	"caption a bound particle has no path and does not move. it stands as a\n" +
	"caption wave, and psi^2 is where you would find it if you looked.\n" +
	"caption only some E keep psi finite out here: those are the levels.\n" +
	"caption the marker is the solver. parity: below 0.5 even, above odd.\n" +
	"eq potential 0.5 stiffness t t + quartic t sup 4\n" +
	"eq curvature 2.0 mass { potential - energy }\n" +
	"state psi 1.0 - step { parity - 0.5 }\n" +
	"state slope step { parity - 0.5 }\n" +
	"derivative psi slope\n" +
	"derivative slope curvature psi\n" +
	# The well, drawn as a polyline sampled at four radii each side, and
	# the level E across it.  Both are clamped into -1.5..4.5 so a steep
	# well or an inverted one cannot drag the vertical scale off and
	# squash the level flat against the floor; the shape inside the range
	# is exact.  clamp(v) = v - (v-hi)step(v-hi) + (lo-v)step(lo-v).
	"eq hi 4.5\n" +
	"eq lo 0.0 - 1.5\n" +
	"eq v1 0.1953125 stiffness + 0.152587890625 quartic\n" +
	"eq v2 0.78125 stiffness + 2.44140625 quartic\n" +
	"eq v3 1.7578125 stiffness + 12.359619140625 quartic\n" +
	"eq v4 3.125 stiffness + 39.0625 quartic\n" +
	"eq v5 4.8828125 stiffness + 95.367431640625 quartic\n" +
	"eq v6 7.03125 stiffness + 197.75390625 quartic\n" +
	"eq v7 9.5703125 stiffness + 366.363525390625 quartic\n" +
	"eq v8 12.5 stiffness + 625 quartic\n" +
	"eq c1 v1 - { v1 - hi } step { v1 - hi } + { lo - v1 } step { lo - v1 }\n" +
	"eq c2 v2 - { v2 - hi } step { v2 - hi } + { lo - v2 } step { lo - v2 }\n" +
	"eq c3 v3 - { v3 - hi } step { v3 - hi } + { lo - v3 } step { lo - v3 }\n" +
	"eq c4 v4 - { v4 - hi } step { v4 - hi } + { lo - v4 } step { lo - v4 }\n" +
	"eq c5 v5 - { v5 - hi } step { v5 - hi } + { lo - v5 } step { lo - v5 }\n" +
	"eq c6 v6 - { v6 - hi } step { v6 - hi } + { lo - v6 } step { lo - v6 }\n" +
	"eq c7 v7 - { v7 - hi } step { v7 - hi } + { lo - v7 } step { lo - v7 }\n" +
	"eq c8 v8 - { v8 - hi } step { v8 - hi } + { lo - v8 } step { lo - v8 }\n" +
	"point wl8 - 5 , c8\n" +
	"point wl7 - 4.375 , c7\n" +
	"point wl6 - 3.75 , c6\n" +
	"point wl5 - 3.125 , c5\n" +
	"point wl4 - 2.5 , c4\n" +
	"point wl3 - 1.875 , c3\n" +
	"point wl2 - 1.25 , c2\n" +
	"point wl1 - 0.625 , c1\n" +
	"point wc 0.0 , 0.0\n" +
	"point wr1 0.625 , c1\n" +
	"point wr2 1.25 , c2\n" +
	"point wr3 1.875 , c3\n" +
	"point wr4 2.5 , c4\n" +
	"point wr5 3.125 , c5\n" +
	"point wr6 3.75 , c6\n" +
	"point wr7 4.375 , c7\n" +
	"point wr8 5 , c8\n" +
	"point levelleft - 5.0 , energy\n" +
	"point levelright 5.0 , energy\n" +
	"point shot t , energy\n" +
	"link wl8 wl7 line\n" +
	"link wl7 wl6 line\n" +
	"link wl6 wl5 line\n" +
	"link wl5 wl4 line\n" +
	"link wl4 wl3 line\n" +
	"link wl3 wl2 line\n" +
	"link wl2 wl1 line\n" +
	"link wl1 wc line\n" +
	"link wc wr1 line\n" +
	"link wr1 wr2 line\n" +
	"link wr2 wr3 line\n" +
	"link wr3 wr4 line\n" +
	"link wr4 wr5 line\n" +
	"link wr5 wr6 line\n" +
	"link wr6 wr7 line\n" +
	"link wr7 wr8 line\n" +
	"link levelleft levelright accent\n" +
	"plain wc wl8 wl7 wl6 wl5 wl4 wl3 wl2 wl1 wr1 wr2 wr3 wr4 wr5 wr6 wr7 wr8 levelleft levelright\n" +
	"observable amplitude psi\n" +
	"observable probability psi psi\n" +
	# the area under psi^2 IS the probability, so draw it as an area
	"shade probability\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:schrodinger: cannot load danbylab";
	if((e := danbylab->run(ctxt, "schrodinger", SPEC)) != nil)
		raise "fail:schrodinger: "+e;
}
