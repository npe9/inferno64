#!/dis/danby/model.dis
#
# danby/internalcompetition - predator-prey with internal competition
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Predator-prey with internal competition
param prey_birth 1.5 0.0 3.0
param prey_crowding 0.5 0.0 2.0
param predation 1.0 0.0 3.0
param conversion 1.0 0.0 3.0
param predator_death 0.5 0.0 2.0
param predator_crowding 0.4 0.0 2.0
maxtime 100.0
state prey 0.55
state predators 0.22
derivative prey prey { prey_birth - prey_crowding prey - predation predators }
derivative predators predators { conversion prey - predator_death - predator_crowding predators }
equilibrium { prey_birth predator_crowding + predation predator_death } over { prey_crowding predator_crowding + predation conversion } , { prey_birth conversion - prey_crowding predator_death } over { prey_crowding predator_crowding + predation conversion }
