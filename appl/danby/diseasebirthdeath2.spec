#!/dis/danby/model.dis
#
# danby/diseasebirthdeath2 - disease with independent birth, death and virulence
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Disease with independent birth, death, and virulence
param contact 2.2 0.0 5.0
param recovery 0.55 0.0 2.0
param birth 0.035 0.0 0.5
param natural_death 0.025 0.0 0.5
param virulence 0.08 0.0 0.8
maxtime 100.0
state susceptible 0.99
state infectious 0.01
state recovered 0.0
# the incidence is per head, so an empty population is a special case:
# alive is 0 there and holds the denominator at one as well as zeroing
# every rate, which is what the original's early return did
eq total susceptible + infectious + recovered
eq alive 1.0 - step { 0.000000000001 - total }
eq infections alive contact susceptible infectious over { total + 1.0 - alive }
derivative susceptible alive { birth total - natural_death susceptible } - infections
derivative infectious infections - alive { recovery + natural_death + virulence } infectious
derivative recovered alive { recovery infectious - natural_death recovered }
