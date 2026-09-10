#!/dis/danby/model.dis
#
# danby/periodicvolterra - the Volterra model with a periodic birthrate
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Volterra model with periodic birthrate
param mean_birth 1.5 0.0 3.0
param predation 2.0 0.0 4.0
param conversion 1.0 0.0 3.0
param predator_death 0.75 0.0 3.0
param seasonality 0.25 0.0 0.95
param frequency 1.0 0.0 3.0
maxtime 100.0
state prey 0.55
state predators 0.22
eq birth mean_birth { 1.0 + seasonality cos { frequency t } }
derivative prey birth prey - predation prey predators
derivative predators conversion prey predators - predator_death predators
equilibrium predator_death over conversion , mean_birth over predation
