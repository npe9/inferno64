#!/dis/danby/model.dis
#
# danby/seasonaldisease - seasonal changes in infectiousness
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Seasonal changes in infectiousness
param mean_contact 2.0 0.0 5.0
param seasonality 0.45 0.0 0.95
param frequency 1.0 0.0 3.0
param recovery 0.55 0.0 2.0
maxtime 100.0
state susceptible 0.99
state infectious 0.01
state recovered 0.0
eq contact mean_contact { 1.0 + seasonality cos { frequency t } }
eq infections contact susceptible infectious
eq recoveries recovery infectious
derivative susceptible - infections
derivative infectious infections - recoveries
derivative recovered recoveries
