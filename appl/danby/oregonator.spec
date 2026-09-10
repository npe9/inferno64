#!/dis/danby/model.dis
#
# danby/oregonator - the Oregonator
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title The Oregonator
param timescale 3.0 0.0 12.0
param q 0.002 0.0 0.05
param stoichiometric_f 1.2 0.0 4.0
param catalyst_rate 0.8 0.0 4.0
maxtime 100.0
state bromous_acid 0.2
state bromide 0.3
state oxidized_catalyst 0.1
derivative bromous_acid timescale { bromide + bromous_acid { 1.0 - q bromous_acid } - bromous_acid bromous_acid }
derivative bromide { - bromide - bromous_acid bromide + stoichiometric_f oxidized_catalyst } over timescale
derivative oxidized_catalyst catalyst_rate { bromous_acid - oxidized_catalyst }
