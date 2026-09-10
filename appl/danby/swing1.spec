#!/dis/danby/model.dis
#
# danby/swing1 - a child on a swing, pumping by moving the centre of mass
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A child on a swing: changing centre of mass
param length 2.0 0.4 5.0
param initial_angle 0.35 -1.2 1.2
param gravity 9.81 0.1 20.0
param damping 0.12 0.0 1.0
param pump 0.18 0.0 0.45
param pump_rate 1.1 0.1 5.0
maxtime 35.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq l length { 1.0 - pump cos { 2.0 phase } }
eq lengthrate 2.0 length pump pump_rate sin { 2.0 phase }
eq x l sin { theta }
eq y - l cos { theta }
derivative theta omega
derivative omega { - 2.0 lengthrate omega } over l - { gravity sin { theta } } over l - damping omega
derivative phase pump_rate
point pivot 0.0 , 0.0
point seat x , y
point child x , { y + 0.28 }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link pivot seat
link seat child
link rail_left rail_right
observable angle theta
observable angular_speed omega
