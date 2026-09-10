#!/dis/danby/model.dis
#
# danby/compass - a compass in an oscillating magnetic field
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A compass in an oscillating magnetic field
param magnetic_torque 2.0 0.0 8.0
param damping 0.15 0.0 2.0
param field_amplitude 1.0 0.0 3.14
param field_rate 1.4 0.1 6.0
param initial_angle 0.2 -3.0 3.0
maxtime 40.0
state theta initial_angle
state omega 0.0
state phase 0.0
eq fieldangle field_amplitude sin { phase }
derivative theta omega
derivative omega - magnetic_torque sin { theta - fieldangle } - damping omega
derivative phase field_rate
point needle_south { - cos { theta } } , { - sin { theta } }
point needle_north cos { theta } , sin { theta }
point field_south { - 1.3 cos { fieldangle } } , { - 1.3 sin { fieldangle } }
point field_north { 1.3 cos { fieldangle } } , { 1.3 sin { fieldangle } }
link needle_south needle_north
link field_south field_north
observable needle_angle theta
observable field_angle fieldangle
