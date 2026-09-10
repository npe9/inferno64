#!/dis/danby/model.dis
#
# danby/enzymekinetics - enzyme kinetics
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Enzyme kinetics
param binding 2.0 0.0 8.0
param unbinding 0.6 0.0 4.0
param catalysis 0.8 0.0 4.0
maxtime 100.0
state substrate 1.5
state enzyme 0.4
state complex 0.0
state product 0.0
# mass action: a negative concentration is clamped to zero before it
# enters a rate, which is what the shared rate library does
eq cS { substrate + abs { substrate } } over 2.0
eq cE { enzyme + abs { enzyme } } over 2.0
eq cC { complex + abs { complex } } over 2.0
eq bind binding cS cE
eq unbind unbinding cC
eq catalyse catalysis cC
derivative substrate - bind + unbind
derivative enzyme - bind + unbind + catalyse
derivative complex bind - unbind - catalyse
derivative product catalyse
