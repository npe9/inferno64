#!/dis/danby/model.dis
#
# danby/dumbbellsatellite - a dumbbell satellite
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A dumbbell satellite
param orbit_radius 2.0 1.0 5.0
param body_length 0.55 0.1 2.0
param orbital_rate 1.0 0.05 3.0
param initial_attitude 0.9 -3.0 3.0
param damping 0.015 0.0 0.5
maxtime 30.0
state phase 0.0
state attitude initial_attitude
state rate 0.0
eq cx orbit_radius cos { phase }
eq cy orbit_radius sin { phase }
eq absangle phase + attitude
eq h body_length over 2.0
eq dx h cos { absangle }
eq dy h sin { absangle }
derivative phase orbital_rate
derivative attitude rate
derivative rate - 1.5 orbital_rate orbital_rate sin { 2.0 attitude } - damping rate
point centre 0.0 , 0.0
point end_a { cx - dx } , { cy - dy }
point end_b { cx + dx } , { cy + dy }
point body cx , cy
link end_a end_b
link centre body
observable orbital_phase phase
observable relative_attitude attitude
