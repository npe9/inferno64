#!/dis/danby/model.dis
#
# danby/synchronousmotor - pull-out torques of synchronous motors
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Pull-out torques of synchronous motors
param field_speed 4.0 0.1 10.0
param maximum_torque 2.0 0.1 8.0
param load_torque 0.8 -4.0 4.0
param inertia 1.0 0.1 5.0
param damping 0.18 0.0 2.0
param initial_lag 0.0 -3.14 3.14
maxtime 30.0
state lag initial_lag
state slip 0.0
derivative lag slip
derivative slip { load_torque - maximum_torque sin { lag } - damping slip } over inertia
point centre 0.0 , 0.0
point rotor cos { lag } , sin { lag }
point stator_centre 0.0 , 0.0
point stator_east 1.0 , 0.0
point stator_west - 1.0 , 0.0
point stator_south 0.0 , - 1.0
link centre rotor
link stator_centre stator_east
link stator_west stator_south
observable phase_lag lag
observable slip_speed slip
