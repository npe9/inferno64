#!/dis/danby/model.dis
#
# danby/moontrip - a trip to the Moon
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title A trip to the Moon
param Moon_mass 0.0123 0.001 0.05
param launch_radius 0.06 0.02 0.15
param launch_offset 0.0 -0.08 0.08
param launch_speed 3.7 0.5 6.0
param launch_angle 0.18 -1.0 1.0
param softening 0.002 0.0002 0.02
maxtime 12.0
body Earth 1.0
body Moon Moon_mass
body craft 0.000001
state xE - Moon_mass over { 1.0 + Moon_mass }
state yE 0.0
state vxE 0.0
state vyE - sqrt { 1.0 + Moon_mass } Moon_mass over { 1.0 + Moon_mass }
state xM 1.0 - Moon_mass over { 1.0 + Moon_mass }
state yM 0.0
state vxM 0.0
state vyM sqrt { 1.0 + Moon_mass } { 1.0 - Moon_mass over { 1.0 + Moon_mass } }
state xC - Moon_mass over { 1.0 + Moon_mass } + launch_radius
state yC launch_offset
state vxC launch_speed cos { launch_angle }
state vyC - sqrt { 1.0 + Moon_mass } Moon_mass over { 1.0 + Moon_mass } + launch_speed sin { launch_angle }
# Newtonian gravity between every pair, softened so a close
# approach stays finite.  3 bodies is 3 pairs, written out.
eq soft2 softening softening
eq dxEM xM - xE
eq dyEM yM - yE
eq rEM dxEM dxEM + dyEM dyEM + soft2
eq iEM 1.0 over { rEM sqrt { rEM } }
eq fxEM 1.0 dxEM iEM
eq fyEM 1.0 dyEM iEM
eq dxEC xC - xE
eq dyEC yC - yE
eq rEC dxEC dxEC + dyEC dyEC + soft2
eq iEC 1.0 over { rEC sqrt { rEC } }
eq fxEC 1.0 dxEC iEC
eq fyEC 1.0 dyEC iEC
eq dxMC xC - xM
eq dyMC yC - yM
eq rMC dxMC dxMC + dyMC dyMC + soft2
eq iMC 1.0 over { rMC sqrt { rMC } }
eq fxMC 1.0 dxMC iMC
eq fyMC 1.0 dyMC iMC
derivative xE vxE
derivative yE vyE
derivative vxE Moon_mass fxEM + 0.000001 fxEC
derivative vyE Moon_mass fyEM + 0.000001 fyEC
derivative xM vxM
derivative yM vyM
derivative vxM - 1.0 fxEM + 0.000001 fxMC
derivative vyM - 1.0 fyEM + 0.000001 fyMC
derivative xC vxC
derivative yC vyC
derivative vxC - 1.0 fxEC - Moon_mass fxMC
derivative vyC - 1.0 fyEC - Moon_mass fyMC
observable Earth_distance sqrt { { xC - xE } { xC - xE } + { yC - yE } { yC - yE } }
observable Moon_distance sqrt { { xC - xM } { xC - xM } + { yC - yM } { yC - yM } }
