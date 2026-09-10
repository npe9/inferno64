#!/dis/danby/model.dis
#
# danby/cannibalism - an age-structured population with cannibalism
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Age-structured population with cannibalism
param birth 1.2 0.0 3.0
param maturation 0.55 0.0 2.0
param cannibalism 0.75 0.0 3.0
param food_conversion 0.4 0.0 1.0
param young_death 0.25 0.0 1.5
param adult_death 0.18 0.0 1.5
maxtime 100.0
state young 0.45
state adults 0.3
eq consumed cannibalism young adults
derivative young birth adults - maturation young - young_death young - consumed
derivative adults maturation young + food_conversion consumed - adult_death adults
