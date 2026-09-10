#!/dis/danby/model.dis
#
# danby/moreenzyme - reversible enzyme kinetics
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Reversible enzyme kinetics
param binding 2.0 0.0 8.0
param unbinding 0.5 0.0 4.0
param forward_catalysis 0.8 0.0 4.0
param reverse_catalysis 0.35 0.0 4.0
maxtime 100.0
state substrate 1.4
state enzyme 0.4
state complex 0.0
state product 0.0
eq cS { substrate + abs { substrate } } over 2.0
eq cE { enzyme + abs { enzyme } } over 2.0
eq cC { complex + abs { complex } } over 2.0
eq cP { product + abs { product } } over 2.0
eq bind binding cS cE
eq unbind unbinding cC
eq forward forward_catalysis cC
eq reverse reverse_catalysis cE cP
derivative substrate - bind + unbind
derivative enzyme - bind + unbind + forward - reverse
derivative complex bind - unbind - forward + reverse
derivative product forward - reverse
