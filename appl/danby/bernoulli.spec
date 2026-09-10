#!/dis/danby/model.dis
#
# danby/bernoulli - Bernoulli's brachistochrone problem
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Bernoulli's brachistochrone problem
param cycloid_scale 1.0 0.2 4.0
param gravity 9.81 0.1 20.0
param end_parameter 3.141592653589793 1.0 6.0
param start_parameter 0.02 0.001 0.5
maxtime 8.0
state theta start_parameter
state along 0.0
state alongspeed 0.0
eq endx cycloid_scale { end_parameter - sin { end_parameter } }
eq endy cycloid_scale { 1.0 - cos { end_parameter } }
eq chord sqrt { endx endx + endy endy }
# the drawing stops at the end of each path; the equations do not
eq shown { theta + end_parameter - abs { theta - end_parameter } } over 2.0
eq fraction { { along over chord } + 1.0 - abs { { along over chord } - 1.0 } } over 2.0
derivative theta sqrt { gravity over cycloid_scale }
derivative along alongspeed
derivative alongspeed gravity endy over chord
point start 0.0 , 0.0
point finish endx , { - endy }
point cycloid_bead { cycloid_scale { shown - sin { shown } } } , { - cycloid_scale { 1.0 - cos { shown } } }
point straight_bead { fraction endx } , { - fraction endy }
link start finish
observable cycloid_progress theta over end_parameter
observable straight_progress along over chord
