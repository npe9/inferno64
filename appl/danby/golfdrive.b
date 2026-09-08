implement Golfdrive;

# danby/golfdrive - Driving a golf ball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Golfdrive: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family trajectory\n" +
	"title Driving a golf ball\n" +
	"param ball_speed 70.0 0.0 100.0\n" +
	"param launch_angle 0.22 0.0 0.8\n" +
	"param drag 0.004 0.0 0.02\n" +
	"param lift 0.00055 0.0 0.003\n" +
	"param backspin 250.0 0.0 500.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 15.0\n" +
	"state x 0.0\n" +
	"state y 0.0\n" +
	"state vx ball_speed cos { launch_angle }\n" +
	"state vy ball_speed sin { launch_angle }\n" +
	"eq v sqrt { vx vx + vy vy }\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - drag v vx - lift backspin vy\n" +
	"derivative vy - gravity - drag v vy + lift backspin vx\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:golfdrive: cannot load danbylab";
	if((e := danbylab->run(ctxt, "golfdrive", SPEC)) != nil)
		raise "fail:golfdrive: "+e;
}
