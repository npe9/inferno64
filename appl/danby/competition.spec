#!/dis/danby/model.dis
#
# danby/competition - competition between two species
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title Competition between two species
scale 1.5
param growth_A 1.0 0.0 2.0
param growth_B 0.8 0.0 2.0
param competition 0.7 0.0 2.0
maxtime 100.0
state species_A 0.55
state species_B 0.22
derivative species_A growth_A species_A { 1.0 - species_A - competition species_B }
derivative species_B growth_B species_B { 1.0 - species_B - competition species_A }
# a symmetric coexistence, which exists for any competition at all - the
# question the model asks is whether it is stable
equilibrium 1.0 over { 1.0 + competition } , 1.0 over { 1.0 + competition }
