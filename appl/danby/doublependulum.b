implement Doublependulum;

# danby/doublependulum - a double pendulum
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

Doublependulum: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title A double pendulum\n" +
	"param mass_1 1.0 0.1 5.0\n" +
	"param mass_2 1.0 0.1 5.0\n" +
	"param length_1 1.0 0.2 3.0\n" +
	"param length_2 1.0 0.2 3.0\n" +
	"param angle_1 1.1 -3.0 3.0\n" +
	"param angle_2 1.6 -3.0 3.0\n" +
	"param gravity 9.81 0.1 20.0\n" +
	"param damping 0.01 0.0 0.5\n" +
	"maxtime 30.0\n" +
	"state a1 angle_1\n" +
	"state w1 0.0\n" +
	"state a2 angle_2\n" +
	"state w2 0.0\n" +
	"eq delta a1 - a2\n" +
	"eq cd cos { delta }\n" +
	"eq sd sin { delta }\n" +
	"eq den 2.0 mass_1 + mass_2 - mass_2 cos { 2.0 delta }\n" +
	"eq num1 - gravity { 2.0 mass_1 + mass_2 } sin { a1 } - mass_2 gravity sin { a1 - 2.0 a2 } - 2.0 sd mass_2 { w2 w2 length_2 + w1 w1 length_1 cd }\n" +
	"eq num2 2.0 sd { w1 w1 length_1 { mass_1 + mass_2 } + gravity { mass_1 + mass_2 } cos { a1 } + w2 w2 length_2 mass_2 cd }\n" +
	"eq x1 length_1 sin { a1 }\n" +
	"eq y1 - length_1 cos { a1 }\n" +
	"eq x2 x1 + length_2 sin { a2 }\n" +
	"eq y2 y1 - length_2 cos { a2 }\n" +
	"derivative a1 w1\n" +
	"derivative w1 num1 over { length_1 den } - damping w1\n" +
	"derivative a2 w2\n" +
	"derivative w2 num2 over { length_2 den } - damping w2\n" +
	"point pivot 0.0 , 0.0\n" +
	"point bob_1 x1 , y1\n" +
	"point bob_2 x2 , y2\n" +
	"point rail_left - 0.7 , 0.0\n" +
	"point rail_right 0.7 , 0.0\n" +
	"link pivot bob_1\n" +
	"link bob_1 bob_2\n" +
	"link rail_left rail_right\n" +
	"observable angle_1 a1\n" +
	"observable angle_2 a2\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:doublependulum: cannot load danbylab";
	if((e := danbylab->run(ctxt, "doublependulum", SPEC)) != nil)
		raise "fail:doublependulum: "+e;
}
