implement Joggingcompanion;

# danby/joggingcompanion - jogging with a companion
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

Joggingcompanion: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Jogging with a companion\n" +
	"param leader_pace 3.2 0.5 8.0\n" +
	"param response 0.8 0.0 3.0\n" +
	"param spacing 1.5 0.2 5.0\n" +
	"param drag 0.7 0.0 2.0\n" +
	"param coupling 0.45 0.0 2.0\n" +
	"param mass 70.0 35.0 120.0\n" +
	"maxtime 25.0\n" +
	"state leader_x 0.0\n" +
	"state leader_v 2.0\n" +
	"state follower_x - 2.5\n" +
	"state follower_v 1.0\n" +
	"eq separation leader_x - follower_x\n" +
	"eq separationerror separation - spacing\n" +
	"derivative leader_x leader_v\n" +
	"derivative leader_v response { leader_pace - leader_v } - { drag leader_v } over mass\n" +
	"derivative follower_x follower_v\n" +
	"derivative follower_v response { leader_pace - follower_v } + coupling separationerror - { drag follower_v } over mass\n" +
	"point leader_feet 0.0 , 0.0\n" +
	"point leader_hip 0.0 , 1.0\n" +
	"point leader_head 0.0 , 1.4\n" +
	"point leader_hand_left - 0.35 , 0.45\n" +
	"point leader_hand_right 0.35 , 0.45\n" +
	"point follower_feet { - separation } , 0.0\n" +
	"point follower_hip { - separation } , 1.0\n" +
	"point follower_head { - separation } , 1.4\n" +
	"point follower_hand_left { - separation - 0.35 } , 0.45\n" +
	"point follower_hand_right { - separation + 0.35 } , 0.45\n" +
	"link leader_feet leader_hip\n" +
	"link leader_hip leader_head\n" +
	"link leader_hip leader_hand_left\n" +
	"link leader_hip leader_hand_right\n" +
	"link follower_feet follower_hip\n" +
	"link follower_hip follower_head\n" +
	"link follower_hip follower_hand_left\n" +
	"link follower_hip follower_hand_right\n" +
	"observable leader_speed leader_v\n" +
	"observable separation separation\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	mechlab = load Mechlab Mechlab->PATH;
	if(mechlab == nil)
		raise "fail:joggingcompanion: cannot load mechlab";
	if((e := mechlab->run(ctxt, "joggingcompanion", SPEC)) != nil)
		raise "fail:joggingcompanion: "+e;
}
