#!/dis/danby/model.dis
#
# danby/malaria - human-mosquito malaria transmission
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Human-mosquito malaria transmission
param mosquito_to_human 1.1 0.0 4.0
param human_to_mosquito 1.4 0.0 4.0
param human_recovery 0.35 0.0 2.0
param mosquito_turnover 0.55 0.0 2.0
maxtime 100.0
state susceptible_humans 0.99
state infectious_humans 0.01
state susceptible_mosquitoes 0.98
state infectious_mosquitoes 0.02
eq humaninfection mosquito_to_human susceptible_humans infectious_mosquitoes
eq mosquitoinfection human_to_mosquito susceptible_mosquitoes infectious_humans
derivative susceptible_humans - humaninfection + human_recovery infectious_humans
derivative infectious_humans humaninfection - human_recovery infectious_humans
derivative susceptible_mosquitoes - mosquitoinfection + mosquito_turnover infectious_mosquitoes
derivative infectious_mosquitoes mosquitoinfection - mosquito_turnover infectious_mosquitoes
