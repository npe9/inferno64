#!/dis/danby/model.dis
#
# danby/fishingtwo - the bioeconomics of two fish species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Bioeconomics of two fish species
param growth_A 1.0 0.0 3.0
param capacity_A 1.5 0.0 4.0
param catch_A 0.65 0.0 2.0
param price_A 1.2 0.0 3.0
param growth_B 0.8 0.0 3.0
param capacity_B 1.1 0.0 4.0
param catch_B 0.5 0.0 2.0
param price_B 1.6 0.0 3.0
param cost 0.55 0.0 3.0
param effort_response 0.7 0.0 2.0
maxtime 100.0
state fish_stock_A 0.9
state fish_stock_B 0.7
state fishing_effort 0.3
eq harvesta catch_A fishing_effort fish_stock_A
eq harvestb catch_B fishing_effort fish_stock_B
eq profit price_A catch_A fish_stock_A + price_B catch_B fish_stock_B - cost
derivative fish_stock_A growth_A fish_stock_A { 1.0 - fish_stock_A over capacity_A } - harvesta
derivative fish_stock_B growth_B fish_stock_B { 1.0 - fish_stock_B over capacity_B } - harvestb
derivative fishing_effort effort_response fishing_effort profit
