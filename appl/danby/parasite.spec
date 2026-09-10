#!/dis/danby/model.dis
#
# danby/parasite - the population growth of a parasite
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Population growth of a parasite
param host_growth 1.1 0.0 3.0
param host_capacity 1.5 0.0 3.0
param infection 1.4 0.0 3.0
param conversion 0.75 0.0 2.0
param parasite_death 0.45 0.0 2.0
maxtime 100.0
state hosts 0.8
state parasites 0.12
eq infections infection hosts parasites
derivative hosts host_growth hosts { 1.0 - hosts over host_capacity } - infections
derivative parasites conversion infections - parasite_death parasites
