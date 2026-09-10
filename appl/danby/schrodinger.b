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
SPEC: con
	"family mechanism\n" +
	"title Schrodinger's equation for a particle in a well\n" +
	"param energy 0.5 -1.0 4.0\n" +
	"param stiffness 1.0 -4.0 4.0\n" +
	"param quartic 0.0 0.0 1.0\n" +
	"param mass 1.0 0.5 4.5\n" +
	"param parity 0.0 0.0 1.0\n" +
	"maxtime 5.0\n" +
	"eq potential 0.5 stiffness t t + quartic t sup 4\n" +
	"eq curvature 2.0 mass { potential - energy }\n" +
	"state psi 1.0 - step { parity - 0.5 }\n" +
	"state slope step { parity - 0.5 }\n" +
	"derivative psi slope\n" +
	"derivative slope curvature psi\n" +
	"point centre 0.0 , 0.0\n" +
	"point foot t , 0.0\n" +
	"point crest t , psi\n" +
	"link centre foot\n" +
	"link foot crest\n" +
	"observable amplitude psi\n" +
	"observable probability psi psi\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:schrodinger: cannot load danbylab";
	if((e := danbylab->run(ctxt, "schrodinger", SPEC)) != nil)
		raise "fail:schrodinger: "+e;
}
