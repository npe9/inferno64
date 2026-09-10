#!/dis/danby/model.dis
#
# danby/manyspecies - one prey and two predator species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title One prey and two predator species
param prey_growth 1.4 0.0 3.0
param capacity 1.8 0.0 3.0
param attack_A 1.1 0.0 3.0
param conversion_A 0.8 0.0 2.0
param death_A 0.5 0.0 2.0
param attack_B 0.8 0.0 3.0
param conversion_B 0.7 0.0 2.0
param death_B 0.4 0.0 2.0
maxtime 100.0
state prey 0.9
state predator_A 0.12
state predator_B 0.08
eq consumptiona attack_A prey predator_A
eq consumptionb attack_B prey predator_B
derivative prey prey_growth prey { 1.0 - prey over capacity } - consumptiona - consumptionb
derivative predator_A conversion_A consumptiona - death_A predator_A
derivative predator_B conversion_B consumptionb - death_B predator_B
