implement Fireflies;

# danby/fireflies - synchronizing fireflies
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Fireflies: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Synchronizing fireflies\n" +
	"param mean_frequency 1.0 0.1 5.0\n" +
	"param frequency_spread 0.18 0.0 2.0\n" +
	"param coupling 0.8 0.0 5.0\n" +
	"param initial_spread 0.1 0.0 6.28\n" +
	"maxtime 45.0\n" +
	"state p0 0.0\n" +
	"state p1 0.23 initial_spread\n" +
	"state p2 0.61 initial_spread\n" +
	"state p3 0.91 initial_spread\n" +
	# four fireflies, each pulled towards every other including itself, which
	# contributes nothing; the original's double loop written out
	"eq c0 sin { p0 - p0 } + sin { p1 - p0 } + sin { p2 - p0 } + sin { p3 - p0 }\n" +
	"eq c1 sin { p0 - p1 } + sin { p1 - p1 } + sin { p2 - p1 } + sin { p3 - p1 }\n" +
	"eq c2 sin { p0 - p2 } + sin { p1 - p2 } + sin { p2 - p2 } + sin { p3 - p2 }\n" +
	"eq c3 sin { p0 - p3 } + sin { p1 - p3 } + sin { p2 - p3 } + sin { p3 - p3 }\n" +
	"eq o0 frequency_spread { 0.0 - 1.5 } over 1.5\n" +
	"eq o1 frequency_spread { 1.0 - 1.5 } over 1.5\n" +
	"eq o2 frequency_spread { 2.0 - 1.5 } over 1.5\n" +
	"eq o3 frequency_spread { 3.0 - 1.5 } over 1.5\n" +
	"derivative p0 mean_frequency + o0 + coupling c0 over 4.0\n" +
	"derivative p1 mean_frequency + o1 + coupling c1 over 4.0\n" +
	"derivative p2 mean_frequency + o2 + coupling c2 over 4.0\n" +
	"derivative p3 mean_frequency + o3 + coupling c3 over 4.0\n" +
	"eq r0 0.8 + 0.25 cos { p0 }\n" +
	"eq r1 0.8 + 0.25 cos { p1 }\n" +
	"eq r2 0.8 + 0.25 cos { p2 }\n" +
	"eq r3 0.8 + 0.25 cos { p3 }\n" +
	"eq a0 { 2.0 PI 0.0 } over 4.0\n" +
	"eq a1 { 2.0 PI 1.0 } over 4.0\n" +
	"eq a2 { 2.0 PI 2.0 } over 4.0\n" +
	"eq a3 { 2.0 PI 3.0 } over 4.0\n" +
	"eq sumc cos { p0 } + cos { p1 } + cos { p2 } + cos { p3 }\n" +
	"eq sums sin { p0 } + sin { p1 } + sin { p2 } + sin { p3 }\n" +
	"point fly_0 { r0 cos { a0 } } , { r0 sin { a0 } }\n" +
	"point fly_1 { r1 cos { a1 } } , { r1 sin { a1 } }\n" +
	"point fly_2 { r2 cos { a2 } } , { r2 sin { a2 } }\n" +
	"point fly_3 { r3 cos { a3 } } , { r3 sin { a3 } }\n" +
	"link fly_0 fly_1\n" +
	"link fly_1 fly_2\n" +
	"link fly_2 fly_3\n" +
	"link fly_3 fly_0\n" +
	"observable coherence sqrt { sumc sumc + sums sums } over 4.0\n" +
	"observable mean_flash sumc over 4.0\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:fireflies: cannot load danbylab";
	if((e := danbylab->run(ctxt, "fireflies", SPEC)) != nil)
		raise "fail:fireflies: "+e;
}
