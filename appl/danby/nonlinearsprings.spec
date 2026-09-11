#!/dis/danby/model.dis
#
# danby/nonlinearsprings - non-linear springs
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Non-linear springs
param mass 1.0 0.1 5.0
param linear 1.0 -5.0 5.0
param quadratic 0.0 -5.0 5.0
param cubic 0.8 -5.0 5.0
param damping 0.08 0.0 2.0
param initial_x 1.2 -3.0 3.0
maxtime 30.0
state x initial_x
state v 0.0
derivative x v
derivative v { - linear x - quadratic x x - cubic x x x - damping v } over mass
point wall - 2.0 , 0.0
# Nothing pinned the right, so the box's right edge was the mass.
point stop 2.0 , 0.0
point mass_point x , 0.0
point mass_top x , - 0.3
point mass_bottom x , 0.3
link wall mass_point spring
link mass_top mass_bottom
observable displacement x
observable velocity v
plain stop
