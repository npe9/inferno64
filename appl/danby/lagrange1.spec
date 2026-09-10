#!/dis/danby/model.dis
#
# danby/lagrange1 - a space station around L4 or L5
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title A space station around L4 or L5: 1
param position_perturb 0.01 -0.15 0.15
param speed_perturb 0.0 -0.2 0.2
param Moon_mass 0.0123 0.001 0.05
param softening 0.002 0.0002 0.02
param gravity 1.0 0.2 2.0
param L4_or_L5 1.0 -1.0 1.0
maxtime 30.0
body Earth 1.0
body Moon Moon_mass
body station 0.000001
# A state's initial value may use the parameters and nothing else - eq
# lines run per step, not at reset - so the mass ratio, the mean motion
# and the L4/L5 sign are written out here.  The sign is +1 at or above
# zero and -1 below, which is the branch the original takes with an if.
state xE - Moon_mass over { 1.0 + Moon_mass }
state yE 0.0
state vxE 0.0
state vyE - sqrt { gravity { 1.0 + Moon_mass } } Moon_mass over { 1.0 + Moon_mass }
state xM 1.0 - Moon_mass over { 1.0 + Moon_mass }
state yM 0.0
state vxM 0.0
state vyM sqrt { gravity { 1.0 + Moon_mass } } { 1.0 - Moon_mass over { 1.0 + Moon_mass } }
state xS 0.5 - Moon_mass over { 1.0 + Moon_mass } + position_perturb
state yS { 1.0 - 2.0 step { - L4_or_L5 } } 0.8660254
state vxS - sqrt { gravity { 1.0 + Moon_mass } } { 1.0 - 2.0 step { - L4_or_L5 } } 0.8660254
state vyS sqrt { gravity { 1.0 + Moon_mass } } { 0.5 - Moon_mass over { 1.0 + Moon_mass } + position_perturb } + speed_perturb
# Newtonian gravity between every pair, softened so a close
# approach stays finite.  3 bodies is 3 pairs, written out.
eq soft2 softening softening
eq dxEM xM - xE
eq dyEM yM - yE
eq rEM dxEM dxEM + dyEM dyEM + soft2
eq iEM 1.0 over { rEM sqrt { rEM } }
eq fxEM gravity dxEM iEM
eq fyEM gravity dyEM iEM
eq dxES xS - xE
eq dyES yS - yE
eq rES dxES dxES + dyES dyES + soft2
eq iES 1.0 over { rES sqrt { rES } }
eq fxES gravity dxES iES
eq fyES gravity dyES iES
eq dxMS xS - xM
eq dyMS yS - yM
eq rMS dxMS dxMS + dyMS dyMS + soft2
eq iMS 1.0 over { rMS sqrt { rMS } }
eq fxMS gravity dxMS iMS
eq fyMS gravity dyMS iMS
derivative xE vxE
derivative yE vyE
derivative vxE Moon_mass fxEM + 0.000001 fxES
derivative vyE Moon_mass fyEM + 0.000001 fyES
derivative xM vxM
derivative yM vyM
derivative vxM - 1.0 fxEM + 0.000001 fxMS
derivative vyM - 1.0 fyEM + 0.000001 fyMS
derivative xS vxS
derivative yS vyS
derivative vxS - 1.0 fxES - Moon_mass fxMS
derivative vyS - 1.0 fyES - Moon_mass fyMS
observable Earth_distance sqrt { { xS - xE } { xS - xE } + { yS - yE } { yS - yE } }
observable Moon_distance sqrt { { xS - xM } { xS - xM } + { yS - yM } { yS - yM } }
