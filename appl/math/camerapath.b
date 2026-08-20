implement Camerapath;

include "math/camerapath.m";

init()
{
}

at(kfs: array of Keyframe, t: real): (real, real, real, real, real)
{
	n := len kfs;
	if(n == 0)
		return (0.0, 0.0, 0.0, 0.0, 0.0);
	if(n == 1 || t <= kfs[0].t){
		k := kfs[0];
		return (k.x, k.y, k.z, k.yaw, k.pitch);
	}
	if(t >= kfs[n-1].t){
		k := kfs[n-1];
		return (k.x, k.y, k.z, k.yaw, k.pitch);
	}
	for(i := 1; i < n; i++){
		if(t <= kfs[i].t){
			a := kfs[i-1];
			b := kfs[i];
			f := 0.0;
			span := b.t - a.t;
			if(span > 0.0)
				f = (t-a.t)/span;
			x := a.x + (b.x-a.x)*f;
			y := a.y + (b.y-a.y)*f;
			z := a.z + (b.z-a.z)*f;
			yaw := a.yaw + (b.yaw-a.yaw)*f;
			pitch := a.pitch + (b.pitch-a.pitch)*f;
			return (x, y, z, yaw, pitch);
		}
	}
	k := kfs[n-1];
	return (k.x, k.y, k.z, k.yaw, k.pitch);
}
