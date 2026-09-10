#!/dis/danby/model.dis
#
# danby/swing2 - a child on a swing, pumping with a rhythmic torque
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A child on a swing: rhythmic torque
param length 2.0 0.4 5.0
param initial_angle 0.25 -1.2 1.2
param gravity 9.81 0.1 20.0
param damping 0.12 0.0 1.0
param torque 1.0 0.0 8.0
param drive_rate 2.2 0.1 6.0
maxtime 35.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq x length sin { theta }
eq y - length cos { theta }
eq lean 0.3 sin { phase }
derivative theta omega
derivative omega { - gravity sin { theta } } over length - damping omega + { torque sin { phase } } over { length length }
derivative phase drive_rate
point pivot 0.0 , 0.0
point seat x , y
point child { x + lean } , { y + 0.32 }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link pivot seat
link seat child
link rail_left rail_right
observable angle theta
observable angular_speed omega
