#!/dis/danby/model.dis
#
# danby/perihelion - the relativistic motion of a planet's perihelion
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title Relativistic motion of planetary perihelion
param gravity 1.0 0.2 2.0
param perihelion 0.72 0.2 1.5
param speed 1.15 0.2 2.0
param relativity 0.012 0.0 0.08
param softening 0.001 0.0001 0.02
param velocity_offset 0.0 -0.3 0.3
maxtime 80.0
body Sun 1.0
body planet 0.0
state xS 0.0
state yS 0.0
state vxS 0.0
state vyS 0.0
state xP perihelion
state yP 0.0
state vxP 0.0
state vyP speed + velocity_offset
# the Sun is held fixed; the correction term is the leading relativistic
# one, which depends on the specific angular momentum
eq r2 xP xP + yP yP + softening softening
eq r sqrt { r2 }
eq h xP vyP - yP vxP
eq factor { - gravity } over { r2 r } { 1.0 + 3.0 relativity h h over r2 }
derivative xS 0.0
derivative yS 0.0
derivative vxS 0.0
derivative vyS 0.0
derivative xP vxP
derivative yP vyP
derivative vxP factor xP
derivative vyP factor yP
# hoc has atan but not atan2, so the four-quadrant angle is the
# half-angle identity 2*atan(y/(rho+x)), which is exact everywhere except
# on the negative x axis where rho+x is zero and the angle is pi.  The
# origin has no angle at all and is taken as zero, as atan2 does.
eq rho sqrt { xP xP + yP yP }
eq den rho + xP
eq onaxis step { den }
eq safeden den + 1.0 - onaxis
observable radius rho
observable orbit_angle onaxis 2.0 atan { yP over safeden } + { 1.0 - onaxis } step { rho } PI
