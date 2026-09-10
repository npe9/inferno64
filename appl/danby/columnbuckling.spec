#!/dis/danby/model.dis
#
# danby/columnbuckling - dynamic buckling of a column
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Dynamic buckling of a column
param mass 1.0 0.1 5.0
param compressive_load 1.3 -2.0 5.0
param post_buckling 1.0 0.05 5.0
param damping 0.12 0.0 2.0
param initial_offset 0.08 -1.0 1.0
maxtime 30.0
state x initial_offset
state v 0.0
derivative x v
derivative v { compressive_load x - post_buckling x x x - damping v } over mass
point foot 0.0 , - 1.5
point lower { 0.65 x } , - 0.5
point upper x , 0.5
point head 0.0 , 1.5
point base_left - 0.5 , - 1.5
point base_right 0.5 , - 1.5
link foot lower
link lower upper
link upper head
link base_left base_right
observable lateral_deflection x
observable velocity v
