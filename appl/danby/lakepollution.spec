#!/dis/danby/model.dis
#
# danby/lakepollution - pollutant concentration in a lake
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Pollutant concentration in a lake
param input_mass 0.35 0.0 2.0
param lake_volume 1.5 0.0 4.0
param outflow 0.45 0.0 2.0
param decay 0.12 0.0 1.0
maxtime 100.0
state pollutant 0.2
derivative pollutant input_mass over lake_volume - { outflow over lake_volume + decay } pollutant
