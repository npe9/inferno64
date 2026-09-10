#!/dis/danby/model.dis
#
# danby/productionexchange - production and exchange of two goods
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Production and exchange of two goods
param production_A 0.8 0.0 2.0
param use_A 0.5 0.0 2.0
param production_B 0.55 0.0 2.0
param use_B 0.7 0.0 2.0
param exchange 0.45 0.0 2.0
maxtime 100.0
state good_A_inventory 0.7
state good_B_inventory 0.35
eq flow exchange { good_A_inventory - good_B_inventory }
derivative good_A_inventory production_A - use_A good_A_inventory - flow
derivative good_B_inventory production_B - use_B good_B_inventory + flow
