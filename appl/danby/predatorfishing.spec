#!/dis/danby/model.dis
#
# danby/predatorfishing - predator-prey with fishing
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Predator-prey with fishing
param prey_birth 1.5 0.0 3.0
param predation 2.0 0.0 4.0
param conversion 1.0 0.0 3.0
param predator_death 0.75 0.0 3.0
param fishing_effort 0.2 0.0 1.4
maxtime 100.0
state prey 0.55
state predators 0.22
# the boats take both species at the same rate, which is what moves the
# equilibrium the other way from where intuition puts it
derivative prey prey { prey_birth - fishing_effort - predation predators }
derivative predators predators { conversion prey - predator_death - fishing_effort }
equilibrium { predator_death + fishing_effort } over conversion , { prey_birth - fishing_effort } over predation
