implement Shipmotion;

# danby/shipmotion - pitching and rolling at sea
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

Shipmotion: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Pitching and rolling at sea\n" +
	"param wave 0.28 0.0 1.2\n" +
	"param roll_stiffness 2.4 0.1 6.0\n" +
	"param pitch_stiffness 1.5 0.1 6.0\n" +
	"param damping 0.35 0.0 2.0\n" +
	"param roll_frequency 0.8 0.1 3.0\n" +
	"param pitch_frequency 1.15 0.1 3.0\n" +
	"maxtime 30.0\n" +
	"state roll 0.15\n" +
	"state rollrate 0.0\n" +
	"state pitch - 0.08\n" +
	"state pitchrate 0.0\n" +
	"eq cr cos { roll }\n" +
	"eq sr sin { roll }\n" +
	"eq cp cos { pitch }\n" +
	"eq sp sin { pitch }\n" +
	"derivative roll rollrate\n" +
	"derivative rollrate wave sin { roll_frequency t } - roll_stiffness roll - damping rollrate\n" +
	"derivative pitch pitchrate\n" +
	"derivative pitchrate wave sin { pitch_frequency t + 0.7 } - pitch_stiffness pitch - damping pitchrate\n" +
	"point roll_port { - 2.5 - cr } , { 0.8 - sr }\n" +
	"point roll_starboard { - 2.5 + cr } , { 0.8 + sr }\n" +
	"point roll_keel - 2.5 , 0.2\n" +
	"point pitch_bow { - sp } , { 0.8 - cp }\n" +
	"point pitch_stern { 3.0 + sp } , { 0.8 + cp }\n" +
	"point pitch_forefoot 0.0 , 0.2\n" +
	"point pitch_heel 3.0 , 0.2\n" +
	"link roll_port roll_starboard\n" +
	"link roll_port roll_keel\n" +
	"link roll_keel roll_starboard\n" +
	"link pitch_bow pitch_stern\n" +
	"link pitch_bow pitch_forefoot\n" +
	"link pitch_forefoot pitch_heel\n" +
	"link pitch_heel pitch_stern\n" +
	"observable roll roll\n" +
	"observable pitch pitch\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:shipmotion: cannot load danbylab";
	if((e := danbylab->run(ctxt, "shipmotion", SPEC)) != nil)
		raise "fail:shipmotion: "+e;
}
