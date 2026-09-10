#!/dis/danby/model.dis
#
# danby/varyingpendulum - a pendulum whose length varies
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A pendulum with varying length
param mean_length 2.0 0.4 5.0
param initial_angle 0.45 -2.0 2.0
param gravity 9.81 0.1 20.0
param damping 0.08 0.0 1.0
param variation 0.35 0.0 0.8
param rate 1.4 0.1 6.0
maxtime 35.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq length mean_length { 1.0 + variation sin { phase } }
eq lengthrate mean_length variation rate cos { phase }
derivative theta omega
derivative omega { - 2.0 lengthrate omega } over length - { gravity sin { theta } } over length - damping omega
derivative phase rate
point pivot 0.0 , 0.0
point bob { length sin { theta } } , { - length cos { theta } }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link pivot bob
link rail_left rail_right
observable angle theta
observable length length
