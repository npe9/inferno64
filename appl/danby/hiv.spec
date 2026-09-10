#!/dis/danby/model.dis
#
# danby/hiv - the initial spread of HIV
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Initial spread of HIV
param effective_contact 1.4 0.0 4.0
param progression 0.18 0.0 1.0
param AIDS_mortality 0.12 0.0 1.0
maxtime 100.0
state susceptible 0.995
state HIV_infected 0.005
state AIDS 0.0
eq transmission effective_contact susceptible HIV_infected
eq progressing progression HIV_infected
derivative susceptible - transmission
derivative HIV_infected transmission - progressing
derivative AIDS progressing - AIDS_mortality AIDS
