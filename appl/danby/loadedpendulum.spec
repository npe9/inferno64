#!/dis/danby/model.dis
#
# danby/loadedpendulum - the simple pendulum with an added constant load
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The simple pendulum with added constant load
param length 1.0 0.1 4.0
param initial_angle 0.0 -3.0 3.0
param damping 0.12 0.0 2.0
param gravity 9.81 0.1 20.0
param load_torque 2.5 -15.0 15.0
param mass 1.0 0.1 5.0
maxtime 30.0
state theta initial_angle
state omega 0.0
eq s sin { theta }
eq c cos { theta }
eq applied load_torque over { mass length length }
eq bobx length s
eq boby - length c
derivative theta omega
derivative omega { - gravity s } over length - damping omega + applied
point pivot 0.0 , 0.0
point bob bobx , boby
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
point load_root bobx , boby
point load_end { bobx + 0.6 } , boby
link pivot bob
link rail_left rail_right
link load_root load_end
observable angle theta
observable angular_speed omega
