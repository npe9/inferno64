#!/dis/danby/model.dis
#
# danby/changingenvironment - population growth in a changing environment
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Population growth in a changing environment
param growth 1.0 0.0 3.0
param mean_capacity 1.4 0.0 3.0
param variation 0.45 0.0 0.95
param frequency 0.7 0.0 3.0
maxtime 100.0
state population 0.6
# the carrying capacity swings with the seasons and is held off zero, so
# that the logistic term stays finite at the bottom of the swing
eq raw mean_capacity { 1.0 + variation sin { frequency t } }
eq capacity { raw + 0.00000001 + abs { raw - 0.00000001 } } over 2.0
derivative population growth population { 1.0 - population over capacity }
