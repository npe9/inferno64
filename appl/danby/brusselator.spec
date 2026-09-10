#!/dis/danby/model.dis
#
# danby/brusselator - the Brusselator
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title The Brusselator
param feed_A 1.0 0.0 4.0
param feed_B 3.0 0.0 8.0
maxtime 100.0
state activator_X 1.2
state intermediate_Y 2.4
eq nonlinear activator_X activator_X intermediate_Y
derivative activator_X feed_A - { feed_B + 1.0 } activator_X + nonlinear
derivative intermediate_Y feed_B activator_X - nonlinear
