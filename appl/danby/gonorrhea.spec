#!/dis/danby/model.dis
#
# danby/gonorrhea - two-sex transmission of gonorrhea
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Two-sex transmission of gonorrhea
param men_to_women 1.6 0.0 5.0
param women_to_men 1.3 0.0 5.0
param recovery_women 0.7 0.0 3.0
param recovery_men 0.8 0.0 3.0
maxtime 100.0
state susceptible_women 0.98
state infectious_women 0.02
state susceptible_men 0.99
state infectious_men 0.01
eq infectionswomen men_to_women susceptible_women infectious_men
eq infectionsmen women_to_men susceptible_men infectious_women
eq recoverieswomen recovery_women infectious_women
eq recoveriesmen recovery_men infectious_men
derivative susceptible_women - infectionswomen + recoverieswomen
derivative infectious_women infectionswomen - recoverieswomen
derivative susceptible_men - infectionsmen + recoveriesmen
derivative infectious_men infectionsmen - recoveriesmen
