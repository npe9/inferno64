#!/dis/danby/model.dis
#
# danby/movingpivot - a pendulum with a moving pivot
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A pendulum with moving pivot
param length 1.2 0.2 4.0
param initial_angle 0.18 -2.0 2.0
param gravity 9.81 0.1 20.0
param damping 0.06 0.0 1.5
param pivot_amplitude 0.22 0.0 1.0
param drive_rate 6.0 0.1 12.0
maxtime 30.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq pivotaccel - pivot_amplitude drive_rate drive_rate sin { phase }
eq pivoty pivot_amplitude sin { phase }
derivative theta omega
derivative omega { - { gravity + pivotaccel } sin { theta } } over length - damping omega
derivative phase drive_rate
point pivot 0.0 , pivoty
point bob { length sin { theta } } , { pivoty - length cos { theta } }
point rail_left - 0.7 , pivoty
point rail_right 0.7 , pivoty
# Every point that was not the bob rode up and down with the pivot,
# so the top of the box was the pivot and the pivot never appeared
# to move.  This pins the top; it draws nothing.
point headroom 0.0 , 0.5
link pivot bob
link rail_left rail_right
observable angle theta
observable pivot_height pivoty
plain headroom
