#!/dis/danby/model.dis
#
# danby/poyntingrobertson - the Poynting-Robertson effect
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title The Poynting-Robertson effect
param radius 1.0 0.3 3.0
param speed 1.0 0.2 2.0
param radiation_drag 0.015 0.0 0.08
param radiation_pressure 0.18 0.0 0.8
param softening 0.001 0.0001 0.02
param gravity 1.0 0.2 2.0
maxtime 100.0
body Sun 1.0
body dust 0.0
state xS 0.0
state yS 0.0
state vxS 0.0
state vyS 0.0
state xD radius
state yD 0.0
state vxD 0.0
state vyD speed
# radiation pressure lightens the Sun's pull and the aberration of that
# same radiation drags on the motion, which is the effect this shows
eq r2 xD xD + yD yD + softening softening
eq r sqrt { r2 }
eq gravityfactor { - gravity { 1.0 - radiation_pressure } } over { r2 r }
eq dragfactor { - radiation_drag } over r2
derivative xS 0.0
derivative yS 0.0
derivative vxS 0.0
derivative vyS 0.0
derivative xD vxD
derivative yD vyD
derivative vxD gravityfactor xD + dragfactor vxD
derivative vyD gravityfactor yD + dragfactor vyD
observable radius sqrt { xD xD + yD yD }
observable angular_momentum xD vyD - yD vxD
