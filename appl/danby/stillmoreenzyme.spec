#!/dis/danby/model.dis
#
# danby/stillmoreenzyme - cooperative two-site enzyme kinetics
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Cooperative two-site enzyme kinetics
param first_binding 1.8 0.0 8.0
param first_release 0.5 0.0 4.0
param second_binding 1.5 0.0 8.0
param second_release 0.4 0.0 4.0
param catalysis 0.8 0.0 4.0
maxtime 100.0
state substrate 2.0
state enzyme 0.35
state one_bound 0.0
state two_bound 0.0
state product 0.0
eq cS { substrate + abs { substrate } } over 2.0
eq cE { enzyme + abs { enzyme } } over 2.0
eq c1 { one_bound + abs { one_bound } } over 2.0
eq c2 { two_bound + abs { two_bound } } over 2.0
eq f1 first_binding cS cE
eq r1 first_release c1
eq f2 second_binding cS c1
eq r2 second_release c2
eq cat catalysis c2
derivative substrate - f1 + r1 - f2 + r2
derivative enzyme - f1 + r1 + cat
derivative one_bound f1 - r1 - f2 + r2
derivative two_bound f2 - r2 - cat
derivative product 2.0 cat
