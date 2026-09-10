#!/dis/danby/model.dis
#
# danby/cometcatch - catching a comet with Jupiter
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title If you were Jupiter, could you catch a comet?
param Jupiter_mass 0.001 0.0001 0.01
param Jupiter_radius 5.2 2.0 8.0
param comet_speed 0.35 0.05 1.0
param impact_offset -0.14 -1.0 1.0
param softening 0.018 0.001 0.1
param gravity 1.0 0.2 2.0
maxtime 45.0
body Sun 1.0
body Jupiter Jupiter_mass
body comet 0.0
state xS 0.0
state yS 0.0
state vxS 0.0
state vyS 0.0
state xJ Jupiter_radius
state yJ 0.0
state vxJ 0.0
state vyJ sqrt { gravity over Jupiter_radius }
state xC Jupiter_radius + 2.0
state yC impact_offset
state vxC - comet_speed
state vyC sqrt { gravity over Jupiter_radius }
# Newtonian gravity between every pair, softened so a close
# approach stays finite.  3 bodies is 3 pairs, written out.
eq soft2 softening softening
eq dxSJ xJ - xS
eq dySJ yJ - yS
eq rSJ dxSJ dxSJ + dySJ dySJ + soft2
eq iSJ 1.0 over { rSJ sqrt { rSJ } }
eq fxSJ gravity dxSJ iSJ
eq fySJ gravity dySJ iSJ
eq dxSC xC - xS
eq dySC yC - yS
eq rSC dxSC dxSC + dySC dySC + soft2
eq iSC 1.0 over { rSC sqrt { rSC } }
eq fxSC gravity dxSC iSC
eq fySC gravity dySC iSC
eq dxJC xC - xJ
eq dyJC yC - yJ
eq rJC dxJC dxJC + dyJC dyJC + soft2
eq iJC 1.0 over { rJC sqrt { rJC } }
eq fxJC gravity dxJC iJC
eq fyJC gravity dyJC iJC
derivative xS vxS
derivative yS vyS
derivative vxS Jupiter_mass fxSJ + 0.0 fxSC
derivative vyS Jupiter_mass fySJ + 0.0 fySC
derivative xJ vxJ
derivative yJ vyJ
derivative vxJ - 1.0 fxSJ + 0.0 fxJC
derivative vyJ - 1.0 fySJ + 0.0 fyJC
derivative xC vxC
derivative yC vyC
derivative vxC - 1.0 fxSC - Jupiter_mass fxJC
derivative vyC - 1.0 fySC - Jupiter_mass fyJC
observable comet_energy 0.5 { vxC vxC + vyC vyC } - gravity over sqrt { xC xC + yC yC }
observable Jupiter_distance sqrt { { xC - xJ } { xC - xJ } + { yC - yJ } { yC - yJ } }
