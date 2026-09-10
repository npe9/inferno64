#!/dis/danby/model.dis
#
# danby/decomposition - the decomposition of a molecule
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Decomposition of a molecule
param first_reaction 0.35 0.0 2.0
param second_reaction 0.08 0.0 2.0
maxtime 100.0
state parent 1.0
state intermediate 0.0
state product 0.0
# mass action, first order in one species each: the rate library clamps a
# negative concentration to zero before raising it to its order, which
# for order one is just the clamp
eq p { parent + abs { parent } } over 2.0
eq i { intermediate + abs { intermediate } } over 2.0
eq f1 first_reaction p
eq f2 second_reaction i
derivative parent - f1
derivative intermediate f1 - f2
derivative product f2
