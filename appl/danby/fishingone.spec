#!/dis/danby/model.dis
#
# danby/fishingone - the bioeconomics of one fish species
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Bioeconomics of one fish species
param growth 1.0 0.0 3.0
param capacity 1.5 0.0 4.0
param catchability 0.7 0.0 2.0
param price 1.2 0.0 3.0
param cost 0.45 0.0 2.0
param effort_response 0.8 0.0 2.0
maxtime 100.0
state fish_stock 1.0
state fishing_effort 0.35
eq harvest catchability fishing_effort fish_stock
eq profitpereffort price catchability fish_stock - cost
derivative fish_stock growth fish_stock { 1.0 - fish_stock over capacity } - harvest
derivative fishing_effort effort_response fishing_effort profitpereffort
