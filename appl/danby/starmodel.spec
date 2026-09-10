#!/dis/danby/model.dis
#
# danby/starmodel - An approximate model for a star
#
# The whole model is the script below: its parameters and their ranges,
# the two quantities that vary with radius and the equations that carry
# them outward.  danbylab(2) is a library this calls with that script -
# it owns the window, the march and the controls, and knows nothing about
# this model.
#
family profile
title An approximate model for a star
param central_density 1.0 0.1 5.0
param central_pressure 1.0 0.1 5.0
param polytropic_index 1.5 0.5 4.0
param gravity 1.0 0.1 3.0
param start_radius 0.002 0.0001 0.02
param radius_limit 10.0 2.0 30.0
radius start_radius , radius_limit
samples 320
state density central_density
state mass 4.1887902 start_radius sup 3 central_density
eq gam 1.0 + 1.0 over polytropic_index
eq pressure central_pressure { density over central_density } sup gam
eq live step { density }
eq stiffness live { { { r r gam } pressure } over { density + 1.0 - live } }
eq denom stiffness + 0.00000001
derivative density 0.0 - { { gravity mass density } over denom }
derivative mass 4.0 PI r r density
observable density density over central_density
observable enclosed_mass mass
normalise enclosed_mass
