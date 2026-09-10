#!/dis/danby/model.dis
#
# danby/lanchester - Lanchester square-law combat
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Lanchester square-law combat
param B_effectiveness 0.35 0.0 2.0
param A_effectiveness 0.5 0.0 2.0
maxtime 100.0
state force_A 1.0
state force_B 0.8
derivative force_A - B_effectiveness force_B
derivative force_B - A_effectiveness force_A
