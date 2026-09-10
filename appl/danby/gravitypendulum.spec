#!/dis/danby/model.dis
#
# danby/gravitypendulum - a gravity-gradient pendulum
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A gravity-gradient pendulum
param length 1.0 0.1 4.0
param initial_angle 0.8 -3.0 3.0
param orbital_rate 1.0 0.05 3.0
param damping 0.03 0.0 1.0
maxtime 30.0
state theta initial_angle
state omega 0.0
eq h length over 2.0
eq x h sin { theta }
eq y h cos { theta }
derivative theta omega
derivative omega - 1.5 orbital_rate orbital_rate sin { 2.0 theta } - damping omega
point end_a { - x } , { - y }
point end_b x , y
point rail_left - 1.4 , 0.0
point rail_right 1.4 , 0.0
point centre 0.0 , 0.0
link end_a end_b
link rail_left centre
link centre rail_right
observable attitude theta
observable angular_speed omega
