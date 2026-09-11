implement FFTs;

# The multivariate transform, over the engine in signal(2).
#
# This was Singleton's mixed-radix algorithm (Stanford Research
# Institute, 1968), translated to Limbo by Eric Grosse in 1997, and it
# was wrong: for every length of 8 or more it indexed past the end of
# the array it was given and the process died.  n=8 reached element 10
# of 8, n=16 element 20 of 16.  It worked for the seven shortest
# lengths, and since nothing in the tree ever called it - the one
# apparent caller was a grep matching OFFTHRESH - nobody found out in
# twenty-nine years.
#
# What is kept is the INTERFACE, which is the part worth keeping: the
# Fortran-style multivariate form transforms one variate of a
# multidimensional array in place, so a two-dimensional transform is two
# calls and a three-dimensional one is three, with no copying and no
# separate code for each rank.  The engine underneath is now signal(2),
# which is checked against the direct sum at every length.  The original
# is in the history if anyone wants to fix it as an exercise.

include "sys.m";
	sys: Sys;
include "math.m";
	math: Math;
include "signal.m";
	sig: Signal;
include "ffts.m";

ffts(a, b: array of real, ntot, n, nspan, isn: int)
{
	if(sig == nil){
		sys = load Sys Sys->PATH;
		math = load Math Math->PATH;
		sig = load Signal Signal->PATH;
		if(sig == nil)
			return;
		sig->init();
	}
	if(n < 2 || ntot < n || nspan < n || isn == 0)
		return;
	inc := isn;
	if(inc < 0)
		inc = -inc;
	# the spacing between consecutive values of the variate being
	# transformed, and the size of the block that holds a whole set of
	# them; both in units of the arrays actually passed
	if(nspan % n != 0 || ntot % nspan != 0)
		return;			# the shape does not describe an array
	jc := inc*(nspan/n);
	block := inc*nspan;
	nt := inc*ntot;
	# The highest index touched is nt-inc, not nt-1: the last element
	# of the last variate sits inc short of the end.  That matters
	# exactly in the interleaved case the interface exists for, where b
	# is a[1:] and so is one element shorter than a - demanding nt of
	# it refuses every interleaved call.
	if(nt-inc >= len a || nt-inc >= len b)
		return;

	(re, im) := (array[n] of real, array[n] of real);
	for(base := 0; base < nt; base += block){
		for(off := 0; off < jc; off += inc){
			p := base+off;
			for(j := 0; j < n; j++){
				re[j] = a[p];
				# isn > 0 is the +i convention, which is this
				# transform with the imaginary part turned over on the
				# way in and on the way out
				if(isn > 0)
					im[j] = -b[p];
				else
					im[j] = b[p];
				p += jc;
			}
			sig->fft(re, im);
			p = base+off;
			for(j = 0; j < n; j++){
				a[p] = re[j];
				if(isn > 0)
					b[p] = -im[j];
				else
					b[p] = im[j];
				p += jc;
			}
		}
	}
}
