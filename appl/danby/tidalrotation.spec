#!/dis/danby/model.dis
#
# danby/tidalrotation - Spin-orbit capture with tidal friction
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Spin-orbit capture with tidal friction
param mean_motion 1.0 0.05 3.0
param eccentricity 0.18 0.0 0.8
param triaxiality 0.035 0.0 0.5
param initial_spin 2.4 0.0 5.0
param tidal_friction 0.08 0.0 1.0
maxtime 80.0
state f 0.0
state theta 0.1
state spin initial_spin mean_motion
eq ecosf eccentricity cos { f }
eq onemsq 1.0 - eccentricity sup 2
eq r onemsq over { 1.0 + ecosf }
eq factor 1.0 + ecosf
eq anomalyvelocity mean_motion { factor sup 2 } over { onemsq sup 1.5 }
eq cx r cos { f }
eq cy r sin { f }
eq dx 0.2 cos { theta }
eq dy 0.2 sin { theta }
derivative f anomalyvelocity
derivative theta spin
derivative spin { - 1.5 triaxiality { mean_motion sup 2 } sin { 2.0 { theta - f } } } over { r sup 3 } - tidal_friction { spin - anomalyvelocity }
point centre 0.0 , 0.0
point axis_a { cx - dx } , { cy - dy }
point axis_b { cx + dx } , { cy + dy }
point body cx , cy
link axis_a axis_b
link centre body
observable relative_angle theta - f
observable spin/orbit spin over mean_motion
