#!/dis/danby/model.dis
#
# danby/ecology - predator and prey
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Predator and prey
param prey_birth 1.5 0.0 3.0
param predation 2.0 0.0 4.0
param predator_death 0.75 0.0 3.0
maxtime 100.0
state prey 0.55
state predators 0.22
# Lotka and Volterra's own pair, with the conversion fixed at one: the
# predators eat exactly what the prey lose
derivative prey prey_birth prey - predation prey predators
derivative predators prey predators - predator_death predators
equilibrium predator_death , prey_birth over predation
