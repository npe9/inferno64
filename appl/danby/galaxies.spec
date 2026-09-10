#!/dis/danby/model.dis
#
# danby/galaxies - the gravitational interaction of two galaxies
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title Gravitational interaction between two galaxies
param galaxy_A_mass 2.0 0.2 6.0
param galaxy_B_mass 2.0 0.2 6.0
param separation 4.5 1.0 10.0
param approach_speed 0.25 0.0 1.0
param softening 0.12 0.02 0.6
param gravity 1.0 0.2 2.0
maxtime 35.0
body core_A galaxy_A_mass
body core_B galaxy_B_mass
body A1 0.08
body A2 0.08
body B1 0.08
body B2 0.08
state xA - separation over 2.0
state yA 0.0
state vxA approach_speed
state vyA 0.12
state xB separation over 2.0
state yB 0.0
state vxB - approach_speed
state vyB - 0.12
state xC - separation over 2.0 - 0.8
state yC 0.0
state vxC approach_speed
state vyC - 0.6
state xD - separation over 2.0 + 0.8
state yD 0.0
state vxD approach_speed
state vyD 0.6
state xE separation over 2.0 - 0.8
state yE 0.0
state vxE - approach_speed
state vyE - 0.6
state xF separation over 2.0 + 0.8
state yF 0.0
state vxF - approach_speed
state vyF 0.6
# Newtonian gravity between every pair, softened so a close
# approach stays finite.  6 bodies is 15 pairs, written out.
eq soft2 softening softening
eq dxAB xB - xA
eq dyAB yB - yA
eq rAB dxAB dxAB + dyAB dyAB + soft2
eq iAB 1.0 over { rAB sqrt { rAB } }
eq fxAB gravity dxAB iAB
eq fyAB gravity dyAB iAB
eq dxAC xC - xA
eq dyAC yC - yA
eq rAC dxAC dxAC + dyAC dyAC + soft2
eq iAC 1.0 over { rAC sqrt { rAC } }
eq fxAC gravity dxAC iAC
eq fyAC gravity dyAC iAC
eq dxAD xD - xA
eq dyAD yD - yA
eq rAD dxAD dxAD + dyAD dyAD + soft2
eq iAD 1.0 over { rAD sqrt { rAD } }
eq fxAD gravity dxAD iAD
eq fyAD gravity dyAD iAD
eq dxAE xE - xA
eq dyAE yE - yA
eq rAE dxAE dxAE + dyAE dyAE + soft2
eq iAE 1.0 over { rAE sqrt { rAE } }
eq fxAE gravity dxAE iAE
eq fyAE gravity dyAE iAE
eq dxAF xF - xA
eq dyAF yF - yA
eq rAF dxAF dxAF + dyAF dyAF + soft2
eq iAF 1.0 over { rAF sqrt { rAF } }
eq fxAF gravity dxAF iAF
eq fyAF gravity dyAF iAF
eq dxBC xC - xB
eq dyBC yC - yB
eq rBC dxBC dxBC + dyBC dyBC + soft2
eq iBC 1.0 over { rBC sqrt { rBC } }
eq fxBC gravity dxBC iBC
eq fyBC gravity dyBC iBC
eq dxBD xD - xB
eq dyBD yD - yB
eq rBD dxBD dxBD + dyBD dyBD + soft2
eq iBD 1.0 over { rBD sqrt { rBD } }
eq fxBD gravity dxBD iBD
eq fyBD gravity dyBD iBD
eq dxBE xE - xB
eq dyBE yE - yB
eq rBE dxBE dxBE + dyBE dyBE + soft2
eq iBE 1.0 over { rBE sqrt { rBE } }
eq fxBE gravity dxBE iBE
eq fyBE gravity dyBE iBE
eq dxBF xF - xB
eq dyBF yF - yB
eq rBF dxBF dxBF + dyBF dyBF + soft2
eq iBF 1.0 over { rBF sqrt { rBF } }
eq fxBF gravity dxBF iBF
eq fyBF gravity dyBF iBF
eq dxCD xD - xC
eq dyCD yD - yC
eq rCD dxCD dxCD + dyCD dyCD + soft2
eq iCD 1.0 over { rCD sqrt { rCD } }
eq fxCD gravity dxCD iCD
eq fyCD gravity dyCD iCD
eq dxCE xE - xC
eq dyCE yE - yC
eq rCE dxCE dxCE + dyCE dyCE + soft2
eq iCE 1.0 over { rCE sqrt { rCE } }
eq fxCE gravity dxCE iCE
eq fyCE gravity dyCE iCE
eq dxCF xF - xC
eq dyCF yF - yC
eq rCF dxCF dxCF + dyCF dyCF + soft2
eq iCF 1.0 over { rCF sqrt { rCF } }
eq fxCF gravity dxCF iCF
eq fyCF gravity dyCF iCF
eq dxDE xE - xD
eq dyDE yE - yD
eq rDE dxDE dxDE + dyDE dyDE + soft2
eq iDE 1.0 over { rDE sqrt { rDE } }
eq fxDE gravity dxDE iDE
eq fyDE gravity dyDE iDE
eq dxDF xF - xD
eq dyDF yF - yD
eq rDF dxDF dxDF + dyDF dyDF + soft2
eq iDF 1.0 over { rDF sqrt { rDF } }
eq fxDF gravity dxDF iDF
eq fyDF gravity dyDF iDF
eq dxEF xF - xE
eq dyEF yF - yE
eq rEF dxEF dxEF + dyEF dyEF + soft2
eq iEF 1.0 over { rEF sqrt { rEF } }
eq fxEF gravity dxEF iEF
eq fyEF gravity dyEF iEF
derivative xA vxA
derivative yA vyA
derivative vxA galaxy_B_mass fxAB + 0.08 fxAC + 0.08 fxAD + 0.08 fxAE + 0.08 fxAF
derivative vyA galaxy_B_mass fyAB + 0.08 fyAC + 0.08 fyAD + 0.08 fyAE + 0.08 fyAF
derivative xB vxB
derivative yB vyB
derivative vxB - galaxy_A_mass fxAB + 0.08 fxBC + 0.08 fxBD + 0.08 fxBE + 0.08 fxBF
derivative vyB - galaxy_A_mass fyAB + 0.08 fyBC + 0.08 fyBD + 0.08 fyBE + 0.08 fyBF
derivative xC vxC
derivative yC vyC
derivative vxC - galaxy_A_mass fxAC - galaxy_B_mass fxBC + 0.08 fxCD + 0.08 fxCE + 0.08 fxCF
derivative vyC - galaxy_A_mass fyAC - galaxy_B_mass fyBC + 0.08 fyCD + 0.08 fyCE + 0.08 fyCF
derivative xD vxD
derivative yD vyD
derivative vxD - galaxy_A_mass fxAD - galaxy_B_mass fxBD - 0.08 fxCD + 0.08 fxDE + 0.08 fxDF
derivative vyD - galaxy_A_mass fyAD - galaxy_B_mass fyBD - 0.08 fyCD + 0.08 fyDE + 0.08 fyDF
derivative xE vxE
derivative yE vyE
derivative vxE - galaxy_A_mass fxAE - galaxy_B_mass fxBE - 0.08 fxCE - 0.08 fxDE + 0.08 fxEF
derivative vyE - galaxy_A_mass fyAE - galaxy_B_mass fyBE - 0.08 fyCE - 0.08 fyDE + 0.08 fyEF
derivative xF vxF
derivative yF vyF
derivative vxF - galaxy_A_mass fxAF - galaxy_B_mass fxBF - 0.08 fxCF - 0.08 fxDF - 0.08 fxEF
derivative vyF - galaxy_A_mass fyAF - galaxy_B_mass fyBF - 0.08 fyCF - 0.08 fyDF - 0.08 fyEF
eq kinetic 0.5 galaxy_A_mass { vxA vxA + vyA vyA } + 0.5 galaxy_B_mass { vxB vxB + vyB vyB } + 0.5 0.08 { vxC vxC + vyC vyC } + 0.5 0.08 { vxD vxD + vyD vyD } + 0.5 0.08 { vxE vxE + vyE vyE } + 0.5 0.08 { vxF vxF + vyF vyF }
eq potAB - gravity galaxy_A_mass galaxy_B_mass over sqrt { dxAB dxAB + dyAB dyAB + soft2 }
eq potAC - gravity galaxy_A_mass 0.08 over sqrt { dxAC dxAC + dyAC dyAC + soft2 }
eq potAD - gravity galaxy_A_mass 0.08 over sqrt { dxAD dxAD + dyAD dyAD + soft2 }
eq potAE - gravity galaxy_A_mass 0.08 over sqrt { dxAE dxAE + dyAE dyAE + soft2 }
eq potAF - gravity galaxy_A_mass 0.08 over sqrt { dxAF dxAF + dyAF dyAF + soft2 }
eq potBC - gravity galaxy_B_mass 0.08 over sqrt { dxBC dxBC + dyBC dyBC + soft2 }
eq potBD - gravity galaxy_B_mass 0.08 over sqrt { dxBD dxBD + dyBD dyBD + soft2 }
eq potBE - gravity galaxy_B_mass 0.08 over sqrt { dxBE dxBE + dyBE dyBE + soft2 }
eq potBF - gravity galaxy_B_mass 0.08 over sqrt { dxBF dxBF + dyBF dyBF + soft2 }
eq potCD - gravity 0.08 0.08 over sqrt { dxCD dxCD + dyCD dyCD + soft2 }
eq potCE - gravity 0.08 0.08 over sqrt { dxCE dxCE + dyCE dyCE + soft2 }
eq potCF - gravity 0.08 0.08 over sqrt { dxCF dxCF + dyCF dyCF + soft2 }
eq potDE - gravity 0.08 0.08 over sqrt { dxDE dxDE + dyDE dyDE + soft2 }
eq potDF - gravity 0.08 0.08 over sqrt { dxDF dxDF + dyDF dyDF + soft2 }
eq potEF - gravity 0.08 0.08 over sqrt { dxEF dxEF + dyEF dyEF + soft2 }

observable core_separation sqrt { { xB - xA } { xB - xA } + { yB - yA } { yB - yA } }
observable system_energy kinetic + potAB + potAC + potAD + potAE + potAF + potBC + potBD + potBE + potBF + potCD + potCE + potCF + potDE + potDF + potEF
