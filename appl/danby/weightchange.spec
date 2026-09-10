#!/dis/danby/model.dis
#
# danby/weightchange - body-weight energy balance
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Body-weight energy balance
param energy_intake 10.5 0.0 20.0
param basal_coefficient 0.72 0.0 1.5
param activity 0.035 0.0 0.15
param energy_density 32.2 0.0 60.0
maxtime 100.0
state body_mass 75.0
# basal expenditure goes as the three-quarter power of mass, which is not
# defined below zero, so the mass entering it is clamped there
eq mass { body_mass + abs { body_mass } } over 2.0
eq expenditure basal_coefficient { mass sup 0.75 } + activity mass
derivative body_mass { energy_intake - expenditure } over energy_density
