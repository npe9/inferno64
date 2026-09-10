#!/dis/danby/model.dis
#
# danby/vanderpol - Van der Pol's equation
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Van der Pol's equation
param mu 1.0 0.0 8.0
param frequency 1.0 0.1 5.0
param initial_x 0.2 -4.0 4.0
param initial_velocity 0.0 -4.0 4.0
maxtime 50.0
state x initial_x
state v initial_velocity
derivative x v
derivative v mu { 1.0 - x x } v - frequency frequency x
point wall - 2.0 , 0.0
point mass x , 0.0
point mass_top x , - 0.3
point mass_bottom x , 0.3
link wall mass
link mass_top mass_bottom
observable displacement x
observable velocity v
