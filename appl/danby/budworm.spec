#!/dis/danby/model.dis
#
# danby/budworm - spruce budworm versus balsam fir
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Spruce budworm versus balsam fir
param growth 0.55 0.0 2.0
param foliage_capacity 3.0 0.0 6.0
param bird_predation 1.0 0.0 3.0
param saturation 0.5 0.0 2.0
maxtime 100.0
state budworms 0.35
eq predation bird_predation budworms budworms over { saturation saturation + budworms budworms }
derivative budworms growth budworms { 1.0 - budworms over foliage_capacity } - predation
