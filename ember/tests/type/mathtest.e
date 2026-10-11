module Mathtest

import sys "sys"
import math "math"

// the $Math builtin through module/math.ei: scalar functions,
// tuple-returning modf, array-taking dot/norm2/sort, and folded real
// constants (Pi, Degree, NaN through isnan).

func init() {
	sys.print("%g %g %g %g\n", math.sqrt(2.0), math.pow(2.0, 10.0), math.floor(-2.5), math.fabs(-3.25))
	sys.print("%g %g %g\n", math.sin(math.Pi / 2.0), math.cos(0.0), math.atan2(1.0, 1.0) / math.Degree)
	sys.print("%g %g %d %d\n", math.exp(0.0), math.log(math.exp(1.0)), math.isnan(math.NaN), math.finite(math.Infinity))
	ip, frac := math.modf(3.75)
	sys.print("%d %g %g\n", ip, frac, math.hypot(3.0, 4.0))
	xs := [3]real{3.0, 1.0, 2.0}
	ys := [3]real{1.0, 1.0, 1.0}
	sys.print("%g %g\n", math.dot(xs, ys), math.norm2([2]real{3.0, 4.0}))
	idx := [3]int{0, 1, 2}
	math.sort(xs, idx)
	sys.print("%d %d %d %g\n", idx[0], idx[1], idx[2], xs[idx[0]])
	sys.print("%g\n", math.pow10(3))

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
