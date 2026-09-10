#!/dis/danby/model.dis
#
# danby/logisticpredators - predator-prey with logistic predators
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Predator-prey with logistic predators
param prey_growth 1.5 0.0 3.0
param prey_capacity 1.5 0.0 3.0
param predation 2.0 0.0 4.0
param conversion 1.0 0.0 3.0
param predator_death 0.75 0.0 3.0
param predator_capacity 1.2 0.0 3.0
maxtime 100.0
state prey 0.55
state predators 0.22
derivative prey prey_growth prey { 1.0 - prey over prey_capacity } - predation prey predators
derivative predators predators { conversion prey - predator_death } { 1.0 - predators over predator_capacity }
equilibrium predator_death over conversion , prey_growth { 1.0 - { predator_death over conversion } over prey_capacity } over predation
