#!/dis/danby/model.dis
#
# danby/reactorstability - chemical tank reactor stability
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Chemical tank reactor stability
param residence_time 1.0 0.0 5.0
param feed_concentration 1.0 0.0 4.0
param reaction_rate 2.8 0.0 10.0
param activation 4.0 0.0 12.0
param heat_release 1.2 0.0 6.0
param cooling 0.35 0.0 4.0
maxtime 100.0
state reactant 1.0
state temperature 0.45
# Arrhenius, in the reduced form this family uses: the shifted
# temperature keeps the exponent finite at the bottom of the range
eq rate reaction_rate exp { - activation over { temperature + 1.0 } } reactant
derivative reactant { feed_concentration - reactant } over residence_time - rate
derivative temperature { 0.35 - temperature } over residence_time + heat_release rate - cooling { temperature - 0.25 }
