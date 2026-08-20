Camerapath: module
{
	PATH: con "/dis/math/camerapath.dis";

	# Nelson's Dream Machines "Computer movies" section: the earliest
	# computer-generated animation was exactly this - a camera path
	# keyframed by hand and interpolated frame by frame, long before
	# anything like real-time interactivity existed. One pose per
	# keyframe: position plus a look direction as yaw/pitch degrees,
	# matching draw3d's own rotatey()/rotatex() convention directly so a
	# caller can build its view matrix with the same two calls it would
	# use for any other camera.
	Keyframe: adt {
		t: real;
		x, y, z: real;
		yaw, pitch: real;
	};

	init: fn();
	# Linearly interpolates position and yaw/pitch between the two
	# keyframes bracketing t (clamped to the first/last keyframe outside
	# the recorded range). kfs must be sorted by t ascending. Returns
	# (x, y, z, yaw, pitch).
	at: fn(kfs: array of Keyframe, t: real): (real, real, real, real, real);
};
