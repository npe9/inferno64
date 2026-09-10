#!/dis/danby/model.dis
#
# danby/alternativepredation - predator-prey with saturating predation
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Predator-prey with saturating predation
param prey_birth 1.2 0.0 3.0
param attack 2.0 0.0 4.0
param conversion 1.0 0.0 3.0
param predator_death 0.6 0.0 2.0
param handling 0.5 0.0 2.0
maxtime 100.0
state prey 0.55
state predators 0.22
# a predator takes time to handle what it catches, so its intake
# saturates rather than growing without bound
eq consumption attack prey predators over { 1.0 + handling prey }
derivative prey prey_birth prey - consumption
derivative predators conversion consumption - predator_death predators
# there is a coexistence only while the conversion beats the handling
equilibrium step { conversion attack - predator_death handling } predator_death over { conversion attack - predator_death handling + 1.0 - step { conversion attack - predator_death handling } } , step { conversion attack - predator_death handling } prey_birth { 1.0 + handling step { conversion attack - predator_death handling } predator_death over { conversion attack - predator_death handling + 1.0 - step { conversion attack - predator_death handling } } } over attack
