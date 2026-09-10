#!/dis/danby/model.dis
#
# danby/incubation - an SEIR epidemic with incubation
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title SEIR epidemic with incubation
param contact 2.2 0.0 5.0
param incubation 0.8 0.0 3.0
param recovery 0.55 0.0 2.0
maxtime 100.0
state susceptible 0.99
state exposed 0.005
state infectious 0.005
state recovered 0.0
eq infections contact susceptible infectious
eq progressed incubation exposed
eq recoveries recovery infectious
derivative susceptible - infections
derivative exposed infections - progressed
derivative infectious progressed - recoveries
derivative recovered recoveries
