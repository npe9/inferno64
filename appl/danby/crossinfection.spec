#!/dis/danby/model.dis
#
# danby/crossinfection - cross-infection between two species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Cross-infection between two species
param within_contact 1.8 0.0 5.0
param cross_contact 1.5 0.0 5.0
param recovery_A 0.35 0.0 2.0
param recovery_B 0.5 0.0 2.0
maxtime 100.0
state susceptible_A 0.99
state infectious_A 0.01
state susceptible_B 0.995
state infectious_B 0.005
eq forcea within_contact infectious_A + cross_contact infectious_B
eq forceb within_contact infectious_B + cross_contact infectious_A
eq infectionsa susceptible_A forcea
eq infectionsb susceptible_B forceb
derivative susceptible_A - infectionsa
derivative infectious_A infectionsa - recovery_A infectious_A
derivative susceptible_B - infectionsb
derivative infectious_B infectionsb - recovery_B infectious_B
