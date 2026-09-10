#!/dis/danby/model.dis
#
# danby/grandtour - a grand tour of the Solar System
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title A grand tour of the Solar System
param Jupiter_mass 0.001 0.0001 0.01
param Saturn_mass 0.0003 0.00005 0.003
param Jupiter_radius 5.2 2.0 8.0
param Saturn_radius 9.5 5.0 15.0
param launch_speed 0.52 0.1 1.2
param softening 0.003 0.0002 0.05
maxtime 120.0
body Sun 1.0
body Jupiter Jupiter_mass
body Saturn Saturn_mass
body craft 0.0
state xS 0.0
state yS 0.0
state vxS 0.0
state vyS 0.0
state xJ Jupiter_radius
state yJ 0.0
state vxJ 0.0
state vyJ sqrt { 1.0 over Jupiter_radius }
state xA 0.0
state yA Saturn_radius
state vxA - sqrt { 1.0 over Saturn_radius }
state vyA 0.0
state xC 1.2
state yC 0.0
state vxC 0.0
state vyC launch_speed
# Newtonian gravity between every pair, softened so a close
# approach stays finite.  4 bodies is 6 pairs, written out.
eq soft2 softening softening
eq dxSJ xJ - xS
eq dySJ yJ - yS
eq rSJ dxSJ dxSJ + dySJ dySJ + soft2
eq iSJ 1.0 over { rSJ sqrt { rSJ } }
eq fxSJ 1.0 dxSJ iSJ
eq fySJ 1.0 dySJ iSJ
eq dxSA xA - xS
eq dySA yA - yS
eq rSA dxSA dxSA + dySA dySA + soft2
eq iSA 1.0 over { rSA sqrt { rSA } }
eq fxSA 1.0 dxSA iSA
eq fySA 1.0 dySA iSA
eq dxSC xC - xS
eq dySC yC - yS
eq rSC dxSC dxSC + dySC dySC + soft2
eq iSC 1.0 over { rSC sqrt { rSC } }
eq fxSC 1.0 dxSC iSC
eq fySC 1.0 dySC iSC
eq dxJA xA - xJ
eq dyJA yA - yJ
eq rJA dxJA dxJA + dyJA dyJA + soft2
eq iJA 1.0 over { rJA sqrt { rJA } }
eq fxJA 1.0 dxJA iJA
eq fyJA 1.0 dyJA iJA
eq dxJC xC - xJ
eq dyJC yC - yJ
eq rJC dxJC dxJC + dyJC dyJC + soft2
eq iJC 1.0 over { rJC sqrt { rJC } }
eq fxJC 1.0 dxJC iJC
eq fyJC 1.0 dyJC iJC
eq dxAC xC - xA
eq dyAC yC - yA
eq rAC dxAC dxAC + dyAC dyAC + soft2
eq iAC 1.0 over { rAC sqrt { rAC } }
eq fxAC 1.0 dxAC iAC
eq fyAC 1.0 dyAC iAC
derivative xS vxS
derivative yS vyS
derivative vxS Jupiter_mass fxSJ + Saturn_mass fxSA + 0.0 fxSC
derivative vyS Jupiter_mass fySJ + Saturn_mass fySA + 0.0 fySC
derivative xJ vxJ
derivative yJ vyJ
derivative vxJ - 1.0 fxSJ + Saturn_mass fxJA + 0.0 fxJC
derivative vyJ - 1.0 fySJ + Saturn_mass fyJA + 0.0 fyJC
derivative xA vxA
derivative yA vyA
derivative vxA - 1.0 fxSA - Jupiter_mass fxJA + 0.0 fxAC
derivative vyA - 1.0 fySA - Jupiter_mass fyJA + 0.0 fyAC
derivative xC vxC
derivative yC vyC
derivative vxC - 1.0 fxSC - Jupiter_mass fxJC - Saturn_mass fxAC
derivative vyC - 1.0 fySC - Jupiter_mass fyJC - Saturn_mass fyAC
observable Jupiter_distance sqrt { { xC - xJ } { xC - xJ } + { yC - yJ } { yC - yJ } }
observable Saturn_distance sqrt { { xC - xA } { xC - xA } + { yC - yA } { yC - yA } }
