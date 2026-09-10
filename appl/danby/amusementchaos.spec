#!/dis/danby/model.dis
#
# danby/amusementchaos - chaos in the amusement park
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Chaos in the amusement park
param arm_length 1.0 0.3 3.0
param damping 0.18 0.0 1.0
param drive 1.35 0.0 4.0
param frequency 1.1 0.1 4.0
param pivot_motion 0.25 0.0 1.0
param gravity 9.81 0.0 20.0
maxtime 40.0
state theta 0.3
state omega 0.0
derivative theta omega
derivative omega { - gravity over arm_length } sin { theta } - damping omega + drive cos { frequency t } - pivot_motion sin { 2.0 frequency t } cos { theta }
point pivot 0.0 , 0.0
point car { arm_length sin { theta } } , { - arm_length cos { theta } }
point rail_left - 0.8 , 0.0
point rail_right 0.8 , 0.0
link pivot car
link rail_left rail_right
observable angle theta
observable angular_speed omega
