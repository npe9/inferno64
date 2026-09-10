#!/dis/danby/model.dis
#
# danby/diseasebirthdeath1 - disease with balanced births and deaths
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Disease with balanced births and deaths
param contact 2.2 0.0 5.0
param recovery 0.55 0.0 2.0
param turnover 0.03 0.0 0.5
maxtime 100.0
state susceptible 0.99
state infectious 0.01
state recovered 0.0
eq infections contact susceptible infectious
eq recoveries recovery infectious
derivative susceptible turnover - infections - turnover susceptible
derivative infectious infections - recoveries - turnover infectious
derivative recovered recoveries - turnover recovered
