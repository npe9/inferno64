#!/dis/danby/model.dis
#
# danby/chaoticwheel - a chaotic driven wheel
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A chaotic driven wheel
param gravity_torque 1.0 0.0 5.0
param damping 0.22 0.0 2.0
param drive 1.2 0.0 5.0
param drive_rate 1.1 0.1 5.0
param initial_angle 0.2 -3.0 3.0
maxtime 60.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq x cos { theta }
eq y sin { theta }
derivative theta omega
derivative omega - gravity_torque sin { theta } - damping omega + drive cos { phase }
derivative phase drive_rate
point hub 0.0 , 0.0
point spoke_a x , y
point spoke_b { - x } , { - y }
point rail_left - 1.3 , 0.0
point rail_right 1.3 , 0.0
link spoke_a spoke_b
link rail_left rail_right
observable wheel_angle theta
observable angular_speed omega
