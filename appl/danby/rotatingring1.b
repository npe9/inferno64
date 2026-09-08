implement Rotatingring1;

# danby/rotatingring1 - a ball in a rotating circular ring, at a prescribed speed
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

Rotatingring1: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A ball in a rotating circular ring: prescribed speed\n" +
	"param radius 1.0 0.2 4.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param ring_speed 2.6 0.0 8.0\n" +
	"param damping 0.08 0.0 2.0\n" +
	"param initial_angle 0.35 -3.0 3.0\n" +
	"maxtime 35.0\n" +
	"state theta initial_angle\n" +
	"state omega 0.0\n" +
	"state spin 0.0\n" +
	"eq s sin { theta }\n" +
	"eq c cos { theta }\n" +
	"eq width 0.35 + 0.65 abs { cos { spin } }\n" +
	"eq halfspan width radius\n" +
	"derivative theta omega\n" +
	"derivative omega ring_speed ring_speed s c - gravity s over radius - damping omega\n" +
	"derivative spin ring_speed\n" +
	"point ring_left - halfspan , 0.0\n" +
	"point ring_bottom 0.0 , - radius\n" +
	"point ring_right halfspan , 0.0\n" +
	"point ring_top 0.0 , radius\n" +
	"point ball { halfspan s } , { - radius c }\n" +
	"link ring_left ring_bottom\n" +
	"link ring_bottom ring_right\n" +
	"link ring_right ring_top\n" +
	"link ring_top ring_left\n" +
	"observable ball_angle theta\n" +
	"observable angular_speed omega\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:rotatingring1: cannot load danbylab";
	if((e := danbylab->run(ctxt, "rotatingring1", SPEC)) != nil)
		raise "fail:rotatingring1: "+e;
}
