#!/dis/danby/model.dis
#
# danby/whitedwarf - The limiting mass of a white dwarf
#
# The whole model is the script below: its parameters and their ranges,
# the two quantities that vary with radius and the equations that carry
# them outward.  danbylab(2) is a library this calls with that script -
# it owns the window, the march and the controls, and knows nothing about
# this model.
#
family profile
title The limiting mass of a white dwarf
param central_density 1.0 0.1 10.0
param degeneracy 1.0 0.1 5.0
param gamma 1.3333333 1.2 1.6666667
param gravity 1.0 0.1 3.0
param start_radius 0.002 0.0001 0.02
param radius_limit 8.0 2.0 25.0
radius start_radius , radius_limit
samples 320
state density central_density
state mass 4.1887902 start_radius sup 3 central_density
eq dpdrho { degeneracy gamma } density sup { gamma - 1.0 }
eq denom { r r dpdrho } + 0.00000001
derivative density 0.0 - { { gravity mass density } over denom }
derivative mass 4.0 PI r r density
observable density density over central_density
observable enclosed_mass mass
normalise enclosed_mass
