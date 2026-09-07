implement Balloon;

# danby/balloon - the motion of a balloon and its payload
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  mechlab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "mechlab.m";
	mechlab: Mechlab;

Balloon: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title The motion of a balloon and its payload\n" +
	"param buoyancy 620.0 0.0 1500.0\n" +
	"param drag 12.0 0.0 60.0\n" +
	"param balloon_mass 55.0 10.0 150.0\n" +
	"param tether 4.0 1.0 10.0\n" +
	"param payload_mass 18.0 1.0 80.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 30.0\n" +
	"state altitude 2.0\n" +
	"state rise 0.0\n" +
	"state swing 0.25\n" +
	"state swingrate 0.0\n" +
	"eq totalmass balloon_mass + payload_mass\n" +
	"eq riseaccel { buoyancy - totalmass gravity - drag rise } over totalmass\n" +
	"eq x tether sin { swing }\n" +
	"eq y altitude - tether cos { swing }\n" +
	"derivative altitude rise\n" +
	"derivative rise riseaccel\n" +
	"derivative swing swingrate\n" +
	"derivative swingrate { - gravity over tether } sin { swing } - 0.18 swingrate - { riseaccel sin { swing } } over tether\n" +
	"point hook 0.0 , altitude\n" +
	"point payload x , y\n" +
	"point envelope_left - 0.7 , altitude\n" +
	"point envelope_right 0.7 , altitude\n" +
	"point envelope_top 0.0 , { altitude + 1.0 }\n" +
	"link hook payload\n" +
	"link envelope_left envelope_top\n" +
	"link envelope_top envelope_right\n" +
	"link envelope_right envelope_left\n" +
	"observable altitude altitude\n" +
	"observable payload_swing swing\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:balloon: cannot load mechlab";
	if((e := mechlab->run(ctxt, "balloon", SPEC)) != nil)
		raise "fail:balloon: "+e;
}
