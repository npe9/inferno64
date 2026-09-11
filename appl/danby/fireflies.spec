#!/dis/danby/model.dis
#
# danby/fireflies - synchronizing fireflies
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Synchronizing fireflies
param mean_frequency 1.0 0.1 5.0
param frequency_spread 0.18 0.0 2.0
param coupling 0.8 0.0 5.0
param initial_spread 0.1 0.0 6.28
maxtime 45.0
state p0 0.0
state p1 0.23 initial_spread
state p2 0.61 initial_spread
state p3 0.91 initial_spread
# four fireflies, each pulled towards every other including itself, which
# contributes nothing; the original's double loop written out
eq c0 sin { p0 - p0 } + sin { p1 - p0 } + sin { p2 - p0 } + sin { p3 - p0 }
eq c1 sin { p0 - p1 } + sin { p1 - p1 } + sin { p2 - p1 } + sin { p3 - p1 }
eq c2 sin { p0 - p2 } + sin { p1 - p2 } + sin { p2 - p2 } + sin { p3 - p2 }
eq c3 sin { p0 - p3 } + sin { p1 - p3 } + sin { p2 - p3 } + sin { p3 - p3 }
eq o0 frequency_spread { 0.0 - 1.5 } over 1.5
eq o1 frequency_spread { 1.0 - 1.5 } over 1.5
eq o2 frequency_spread { 2.0 - 1.5 } over 1.5
eq o3 frequency_spread { 3.0 - 1.5 } over 1.5
derivative p0 mean_frequency + o0 + coupling c0 over 4.0
derivative p1 mean_frequency + o1 + coupling c1 over 4.0
derivative p2 mean_frequency + o2 + coupling c2 over 4.0
derivative p3 mean_frequency + o3 + coupling c3 over 4.0
eq r0 0.8 + 0.25 cos { p0 }
eq r1 0.8 + 0.25 cos { p1 }
eq r2 0.8 + 0.25 cos { p2 }
eq r3 0.8 + 0.25 cos { p3 }
eq a0 { 2.0 PI 0.0 } over 4.0
eq a1 { 2.0 PI 1.0 } over 4.0
eq a2 { 2.0 PI 2.0 } over 4.0
eq a3 { 2.0 PI 3.0 } over 4.0
eq sumc cos { p0 } + cos { p1 } + cos { p2 } + cos { p3 }
eq sums sin { p0 } + sin { p1 } + sin { p2 } + sin { p3 }
# The four flies were the only points in the picture, so the box was
# scaled by them and their circling did not show.  These two pin a
# frame a little outside the ring and draw nothing.
point ring_lo - 1.2 , - 1.2
point ring_hi 1.2 , 1.2
point fly_0 { r0 cos { a0 } } , { r0 sin { a0 } }
point fly_1 { r1 cos { a1 } } , { r1 sin { a1 } }
point fly_2 { r2 cos { a2 } } , { r2 sin { a2 } }
point fly_3 { r3 cos { a3 } } , { r3 sin { a3 } }
link fly_0 fly_1
link fly_1 fly_2
link fly_2 fly_3
link fly_3 fly_0
observable coherence sqrt { sumc sumc + sums sums } over 4.0
observable mean_flash sumc over 4.0
plain ring_lo ring_hi
