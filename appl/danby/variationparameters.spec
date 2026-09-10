#!/dis/danby/model.dis
#
# danby/variationparameters - variation of parameters for Van der Pol
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Variation of parameters for Van der Pol
param mu 0.35 0.01 2.0
param frequency 1.0 0.1 5.0
param initial_amplitude 0.35 0.05 4.0
param initial_phase 0.0 -3.14 3.14
maxtime 60.0
state x initial_amplitude cos { initial_phase }
state v - initial_amplitude frequency sin { initial_phase }
state amplitude initial_amplitude
state phase initial_phase
eq averaged amplitude cos { phase }
derivative x v
derivative v mu { 1.0 - x x } v - frequency frequency x
derivative amplitude 0.5 mu amplitude { 1.0 - { amplitude amplitude } over 4.0 }
derivative phase frequency
point wall - 2.0 , 0.0
point numerical x , 0.0
point averaged_wall - 2.0 , - 0.5
point averaged_point averaged , - 0.5
link wall numerical
link averaged_wall averaged_point
observable numerical_x x
observable averaged_x averaged
