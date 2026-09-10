#!/dis/danby/model.dis
#
# danby/windpendulum - the simple pendulum in a stiff wind
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The simple pendulum in a stiff wind
param length 1.0 0.1 4.0
param initial_angle 0.2 -3.0 3.0
param damping 0.1 0.0 2.0
param gravity 9.81 0.1 20.0
param wind 2.4 -12.0 12.0
param area 1.0 0.1 4.0
maxtime 30.0
state theta initial_angle
state omega 0.0
eq s sin { theta }
eq c cos { theta }
derivative theta omega
derivative omega { - gravity s } over length - damping omega + wind area c
point pivot 0.0 , 0.0
point bob { length s } , { - length c }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
point wind_tail - 1.1 , - 0.4
point wind_head - 0.3 , - 0.4
link pivot bob
link rail_left rail_right
link wind_tail wind_head
observable angle theta
observable angular_speed omega
