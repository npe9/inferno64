implement Fireworks;

# danby/fireworks - fireworks
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

Fireworks: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Fireworks\n" +
	"param launch_speed 32.0 5.0 60.0\n" +
	"param fuse 1.8 0.2 4.0\n" +
	"param burst_speed 14.0 1.0 30.0\n" +
	"param drag 0.015 0.0 0.08\n" +
	"param gravity 9.81 0.0 20.0\n" +
	"param symmetry 1.0 0.5 1.5\n" +
	"maxtime 8.0\n" +
	"state x0 0.0\n" +
	"state y0 0.0\n" +
	"state vx0 0.0\n" +
	"state vy0 launch_speed\n" +
	"state x1 0.0\n" +
	"state y1 0.0\n" +
	"state vx1 0.0\n" +
	"state vy1 launch_speed\n" +
	"state x2 0.0\n" +
	"state y2 0.0\n" +
	"state vx2 0.0\n" +
	"state vy2 launch_speed\n" +
	"state x3 0.0\n" +
	"state y3 0.0\n" +
	"state vx3 0.0\n" +
	"state vy3 launch_speed\n" +
	# one sharp push at the fuse time, in four directions a quarter turn
	# apart - the original's Gaussian, whose 5.6418958 is 1/sqrt(pi) times
	# ten so that the impulse integrates to the burst speed
	"eq delta t - fuse\n" +
	"eq burst burst_speed 5.6418958 exp { - 100.0 delta delta }\n" +
	"eq a0 { 2.0 PI 0.0 } over 4.0 symmetry\n" +
	"eq a1 { 2.0 PI 1.0 } over 4.0 symmetry\n" +
	"eq a2 { 2.0 PI 2.0 } over 4.0 symmetry\n" +
	"eq a3 { 2.0 PI 3.0 } over 4.0 symmetry\n" +
	"eq s0 sqrt { vx0 vx0 + vy0 vy0 }\n" +
	"eq s1 sqrt { vx1 vx1 + vy1 vy1 }\n" +
	"eq s2 sqrt { vx2 vx2 + vy2 vy2 }\n" +
	"eq s3 sqrt { vx3 vx3 + vy3 vy3 }\n" +
	"derivative x0 vx0\n" +
	"derivative y0 vy0\n" +
	"derivative vx0 burst cos { a0 } - drag s0 vx0\n" +
	"derivative vy0 burst sin { a0 } - gravity - drag s0 vy0\n" +
	"derivative x1 vx1\n" +
	"derivative y1 vy1\n" +
	"derivative vx1 burst cos { a1 } - drag s1 vx1\n" +
	"derivative vy1 burst sin { a1 } - gravity - drag s1 vy1\n" +
	"derivative x2 vx2\n" +
	"derivative y2 vy2\n" +
	"derivative vx2 burst cos { a2 } - drag s2 vx2\n" +
	"derivative vy2 burst sin { a2 } - gravity - drag s2 vy2\n" +
	"derivative x3 vx3\n" +
	"derivative y3 vy3\n" +
	"derivative vx3 burst cos { a3 } - drag s3 vx3\n" +
	"derivative vy3 burst sin { a3 } - gravity - drag s3 vy3\n" +
	"eq hi01 { x0 + x1 + abs { x0 - x1 } } over 2.0\n" +
	"eq hi23 { x2 + x3 + abs { x2 - x3 } } over 2.0\n" +
	"eq xmax { hi01 + hi23 + abs { hi01 - hi23 } } over 2.0\n" +
	"eq lo01 { x0 + x1 - abs { x0 - x1 } } over 2.0\n" +
	"eq lo23 { x2 + x3 - abs { x2 - x3 } } over 2.0\n" +
	"eq xmin { lo01 + lo23 - abs { lo01 - lo23 } } over 2.0\n" +
	"point spark_0 x0 , y0\n" +
	"point spark_1 x1 , y1\n" +
	"point spark_2 x2 , y2\n" +
	"point spark_3 x3 , y3\n" +
	"point ground_left - 2.0 , 0.0\n" +
	"point ground_right 2.0 , 0.0\n" +
	"link ground_left ground_right\n" +
	"observable mean_altitude { y0 + y1 + y2 + y3 } over 4.0\n" +
	"observable spread xmax - xmin\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:fireworks: cannot load mechlab";
	if((e := mechlab->run(ctxt, "fireworks", SPEC)) != nil)
		raise "fail:fireworks: "+e;
}
