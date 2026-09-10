#!/dis/danby/model.dis
#
# danby/enzymeapplication - enzyme kinetics with competitive inhibition
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Enzyme kinetics with competitive inhibition
param substrate_binding 2.0 0.0 8.0
param unbinding 0.5 0.0 4.0
param catalysis 0.8 0.0 4.0
param inhibitor_binding 1.6 0.0 8.0
param inhibitor_release 0.4 0.0 4.0
maxtime 100.0
state substrate 1.5
state enzyme 0.4
state complex 0.0
state product 0.0
state inhibitor 0.8
state blocked_enzyme 0.0
eq cS { substrate + abs { substrate } } over 2.0
eq cE { enzyme + abs { enzyme } } over 2.0
eq cC { complex + abs { complex } } over 2.0
eq cI { inhibitor + abs { inhibitor } } over 2.0
eq cB { blocked_enzyme + abs { blocked_enzyme } } over 2.0
eq bind substrate_binding cS cE
eq unbind unbinding cC
eq cat catalysis cC
eq block inhibitor_binding cE cI
eq release inhibitor_release cB
derivative substrate - bind + unbind
derivative enzyme - bind + unbind + cat - block + release
derivative complex bind - unbind - cat
derivative product cat
derivative inhibitor - block + release
derivative blocked_enzyme block - release
