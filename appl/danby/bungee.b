implement Bungee;

# danby/bungee - a bungee jump
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

Bungee: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A bungee jump\n" +
	"param cord_length 18.0 2.0 40.0\n" +
	"param stiffness 55.0 5.0 180.0\n" +
	"param mass 45.0 25.0 120.0\n" +
	"param damping 12.0 0.0 60.0\n" +
	"param air_drag 0.8 0.0 5.0\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"maxtime 25.0\n" +
	"state distance 0.0\n" +
	"state speed 0.0\n" +
	# the cord pulls only once it is taut, and only then does its damper act
	"eq slack distance - cord_length\n" +
	"eq extension { slack + abs { slack } } over 2.0\n" +
	"eq taut step { slack }\n" +
	"eq cordforce stiffness extension + taut damping speed\n" +
	"derivative distance speed\n" +
	"derivative speed gravity - { cordforce + air_drag speed } over mass\n" +
	"point platform 0.0 , 0.0\n" +
	"point jumper 0.0 , { - distance }\n" +
	"point rail_left - 0.6 , 0.0\n" +
	"point rail_right 0.6 , 0.0\n" +
	"link platform jumper\n" +
	"link rail_left rail_right\n" +
	"observable fall_distance distance\n" +
	"observable speed speed\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:bungee: cannot load danbylab";
	if((e := danbylab->run(ctxt, "bungee", SPEC)) != nil)
		raise "fail:bungee: "+e;
}
