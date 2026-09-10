#!/dis/danby/model.dis
#
# danby/violinbow - a violin bow acting on a string
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A violin bow acting on a string
param mass 1.0 0.1 5.0
param string_stiffness 20.0 0.5 80.0
param damping 0.25 0.0 4.0
param bow_speed 1.0 -4.0 4.0
param friction 3.0 0.0 12.0
param slip_scale 0.06 0.005 0.5
maxtime 20.0
state x 0.0
state v 0.0
# stick-slip: the bow grips hard while the string moves with it and lets
# go as the relative speed grows
eq relative bow_speed - v
eq grip friction tanh { relative over slip_scale } over { 1.0 + 4.0 relative relative }
derivative x v
derivative v { - string_stiffness x - damping v + grip } over mass
point bridge - 2.0 , 0.0
point string 0.0 , x
point nut 2.0 , 0.0
point bow_left - 1.2 , 0.55
point bow_right 1.2 , 0.55
link bridge string
link string nut
link bow_left bow_right
observable string_displacement x
observable string_velocity v
