#!/dis/danby/model.dis
#
# danby/threebody - the motion of three bodies
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title The motion of three bodies
param mass_A 1.0 0.1 3.0
param mass_B 1.0 0.1 3.0
param mass_C 0.5 0.1 3.0
param gravity 1.0 0.1 3.0
param softening 0.015 0.001 0.1
param perturbation 0.03 -0.2 0.2
maxtime 30.0
body A mass_A
body B mass_B
body C mass_C
state xa - 0.5
state ya - 0.288675
state vxa sqrt { gravity { mass_A + mass_B + mass_C } } 0.288675
state vya - sqrt { gravity { mass_A + mass_B + mass_C } } 0.5
state xb 0.5
state yb - 0.288675
state vxb sqrt { gravity { mass_A + mass_B + mass_C } } 0.288675
state vyb sqrt { gravity { mass_A + mass_B + mass_C } } 0.5 + perturbation
state xc 0.0
state yc 0.57735
state vxc - sqrt { gravity { mass_A + mass_B + mass_C } } 0.57735
state vyc 0.0
# Newtonian gravity between every pair, softened so that a close
# approach stays finite.  Three bodies is three pairs, written out.
eq soft2 softening softening
eq dxab xb - xa
eq dyab yb - ya
eq rab dxab dxab + dyab dyab + soft2
eq iab 1.0 over { rab sqrt { rab } }
eq fxab gravity dxab iab
eq fyab gravity dyab iab
eq dxac xc - xa
eq dyac yc - ya
eq rac dxac dxac + dyac dyac + soft2
eq iac 1.0 over { rac sqrt { rac } }
eq fxac gravity dxac iac
eq fyac gravity dyac iac
eq dxbc xc - xb
eq dybc yc - yb
eq rbc dxbc dxbc + dybc dybc + soft2
eq ibc 1.0 over { rbc sqrt { rbc } }
eq fxbc gravity dxbc ibc
eq fybc gravity dybc ibc
derivative xa vxa
derivative ya vya
derivative vxa mass_B fxab + mass_C fxac
derivative vya mass_B fyab + mass_C fyac
derivative xb vxb
derivative yb vyb
derivative vxb - mass_A fxab + mass_C fxbc
derivative vyb - mass_A fyab + mass_C fybc
derivative xc vxc
derivative yc vyc
derivative vxc - mass_A fxac - mass_B fxbc
derivative vyc - mass_A fyac - mass_B fybc
eq kinetic 0.5 mass_A { vxa vxa + vya vya } + 0.5 mass_B { vxb vxb + vyb vyb } + 0.5 mass_C { vxc vxc + vyc vyc }
eq pab - gravity mass_A mass_B over sqrt { dxab dxab + dyab dyab + soft2 }
eq pac - gravity mass_A mass_C over sqrt { dxac dxac + dyac dyac + soft2 }
eq pbc - gravity mass_B mass_C over sqrt { dxbc dxbc + dybc dybc + soft2 }
observable energy kinetic + pab + pac + pbc
observable angular_momentum mass_A { xa vya - ya vxa } + mass_B { xb vyb - yb vxb } + mass_C { xc vyc - yc vxc }
