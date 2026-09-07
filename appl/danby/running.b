implement Running;

# danby/running - running
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

Running: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Running\n" +
	"param drive 320.0 20.0 700.0\n" +
	"param drag 0.9 0.05 3.0\n" +
	"param mass 70.0 35.0 120.0\n" +
	"param fatigue 0.7 0.0 2.0\n" +
	"param stride 2.2 0.8 4.0\n" +
	"param recovery 0.18 0.0 0.8\n" +
	"maxtime 20.0\n" +
	"state speed 1.0\n" +
	"state tiredness 0.0\n" +
	"state phase 0.0\n" +
	"state distance 0.0\n" +
	# A tired runner cannot push backwards, so the drive is held at zero.
	# ("rear", not "back": back is an eqn motion keyword.)
	"eq raw drive { 1.0 - fatigue tiredness }\n" +
	"eq effective { raw + abs { raw } } over 2.0\n" +
	"eq hipy 1.05 + 0.05 sin { 2.0 phase }\n" +
	"eq shouldery hipy + 0.55\n" +
	"eq front 0.55 sin { phase }\n" +
	"eq rear 0.55 sin { phase + PI }\n" +
	"derivative speed { effective - drag speed speed } over mass\n" +
	"derivative tiredness 0.002 speed speed - recovery tiredness\n" +
	"derivative phase { 2.0 PI speed } over stride\n" +
	"derivative distance speed\n" +
	"point hip 0.0 , hipy\n" +
	"point shoulder 0.08 , shouldery\n" +
	"point head 0.08 , { shouldery + 0.25 }\n" +
	"point knee_front { 0.55 front } , { hipy - 0.45 }\n" +
	"point foot_front front , 0.0\n" +
	"point knee_back { 0.55 rear } , { hipy - 0.45 }\n" +
	"point foot_back rear , 0.0\n" +
	"point hand_back { 0.45 sin { phase + PI } } , { shouldery - 0.25 }\n" +
	"point hand_front { 0.45 sin { phase } } , { shouldery - 0.25 }\n" +
	"link hip shoulder\n" +
	"link shoulder head\n" +
	"link hip knee_front\n" +
	"link knee_front foot_front\n" +
	"link hip knee_back\n" +
	"link knee_back foot_back\n" +
	"link shoulder hand_back\n" +
	"link shoulder hand_front\n" +
	"observable speed speed\n" +
	"observable distance distance\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:running: cannot load mechlab";
	if((e := mechlab->run(ctxt, "running", SPEC)) != nil)
		raise "fail:running: "+e;
}
