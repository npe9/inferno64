#!/dis/danby/model.dis
#
# danby/twocapital - a one-sector economy with two capital stocks
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title One-sector economy with two capital stocks
param productivity 1.0 0.0 3.0
param share_A 0.55 0.0 0.95
param investment_A 0.24 0.0 0.8
param investment_B 0.2 0.0 0.8
param depreciation_A 0.08 0.0 0.5
param depreciation_B 0.06 0.0 0.5
maxtime 100.0
state capital_A 1.0
state capital_B 0.8
# Cobb-Douglas, and a negative stock produces nothing rather than a
# fractional power of a negative number
eq ka { capital_A + abs { capital_A } } over 2.0
eq kb { capital_B + abs { capital_B } } over 2.0
eq output productivity { ka sup share_A } { kb sup { 1.0 - share_A } }
derivative capital_A investment_A output - depreciation_A ka
derivative capital_B investment_B output - depreciation_B kb
