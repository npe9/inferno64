#!/dis/danby/model.dis
#
# danby/childcare - predator-prey with child care
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Predator-prey with child care
param prey_birth 1.4 0.0 3.0
param attack 1.8 0.0 4.0
param conversion 0.9 0.0 2.0
param maturation 0.7 0.0 2.0
param young_death 0.5 0.0 2.0
param adult_death 0.35 0.0 2.0
param care 0.45 0.0 1.0
maxtime 100.0
state prey 0.8
state young 0.12
state adults 0.15
# care trades a lower attack rate for a lower death rate among the young
eq effectiveattack attack { 1.0 - 0.6 care }
eq effectiveyoungdeath young_death { 1.0 - 0.8 care }
eq kills effectiveattack prey adults
derivative prey prey_birth prey - kills
derivative young conversion kills - maturation young - effectiveyoungdeath young
derivative adults maturation young - adult_death adults
