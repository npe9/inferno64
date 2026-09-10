#!/dis/danby/model.dis
#
# danby/swingingcenser - a swinging censer
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A swinging censer
param chain 1.4 0.3 4.0
param initial_angle 0.25 -1.5 1.5
param gravity 9.81 0.1 20.0
param damping 0.12 0.0 1.5
param hand_accel 2.0 0.0 12.0
param rhythm 1.8 0.1 6.0
maxtime 35.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq horizontalaccel hand_accel cos { phase }
eq handx 0.3 sin { phase }
eq x handx + chain sin { theta }
eq y - chain cos { theta }
derivative theta omega
derivative omega { - gravity sin { theta } - horizontalaccel cos { theta } } over chain - damping omega
derivative phase rhythm
point hand handx , 0.0
point censer x , y
point rail_left - 0.8 , 0.0
point rail_right 0.8 , 0.0
point censer_left { x - 0.16 } , y
point censer_right { x + 0.16 } , y
link hand censer
link rail_left rail_right
link censer_left censer_right
observable angle theta
observable angular_speed omega
