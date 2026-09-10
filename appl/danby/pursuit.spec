#!/dis/danby/model.dis
#
# danby/pursuit - curves of pursuit
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Curves of pursuit
param speed 0.5 0.05 3.0
param initial_size 1.0 0.2 3.0
param turn_bias 0.0 -1.0 1.0
maxtime 8.0
state x0 - initial_size
state y0 - initial_size
state x1 initial_size
state y1 - initial_size
state x2 initial_size
state y2 initial_size
state x3 - initial_size
state y3 initial_size
# each chases the next round the ring; the loop is written out
eq dx0 x1 - x0
eq dy0 y1 - y0
eq d0 sqrt { dx0 dx0 + dy0 dy0 } + 0.000001
eq dx1 x2 - x1
eq dy1 y2 - y1
eq d1 sqrt { dx1 dx1 + dy1 dy1 } + 0.000001
eq dx2 x3 - x2
eq dy2 y3 - y2
eq d2 sqrt { dx2 dx2 + dy2 dy2 } + 0.000001
eq dx3 x0 - x3
eq dy3 y0 - y3
eq d3 sqrt { dx3 dx3 + dy3 dy3 } + 0.000001
derivative x0 speed { dx0 - turn_bias dy0 } over d0
derivative y0 speed { dy0 + turn_bias dx0 } over d0
derivative x1 speed { dx1 - turn_bias dy1 } over d1
derivative y1 speed { dy1 + turn_bias dx1 } over d1
derivative x2 speed { dx2 - turn_bias dy2 } over d2
derivative y2 speed { dy2 + turn_bias dx2 } over d2
derivative x3 speed { dx3 - turn_bias dy3 } over d3
derivative y3 speed { dy3 + turn_bias dx3 } over d3
point chaser_0 x0 , y0
point chaser_1 x1 , y1
point chaser_2 x2 , y2
point chaser_3 x3 , y3
link chaser_0 chaser_1
link chaser_1 chaser_2
link chaser_2 chaser_3
link chaser_3 chaser_0
observable separation_01 sqrt { dx0 dx0 + dy0 dy0 }
observable separation_12 sqrt { dx1 dx1 + dy1 dy1 }
