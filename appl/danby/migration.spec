#!/dis/danby/model.dis
#
# danby/migration - the effects of migration on an epidemic
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Effects of migration on an epidemic
param contact 2.2 0.0 5.0
param recovery 0.55 0.0 2.0
param migration 0.08 0.0 1.0
param migrant_infection 0.02 0.0 0.5
maxtime 100.0
state susceptible 0.99
state infectious 0.01
state recovered 0.0
eq infections contact susceptible infectious
eq recoveries recovery infectious
# arrivals carry the same mix whatever the local one is, so migration
# pulls each fraction towards the migrants' own
eq migrantsusceptible 1.0 - migrant_infection
derivative susceptible - infections + migration { migrantsusceptible - susceptible }
derivative infectious infections - recoveries + migration { migrant_infection - infectious }
derivative recovered recoveries - migration recovered
