#!/dis/danby/model.dis
#
# danby/polevault - the pole vault
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The pole vault
param run_speed 9.0 1.0 14.0
param pole_length 5.0 2.0 6.5
param stiffness 1800.0 200.0 4000.0
param damping 35.0 0.0 150.0
param mass 75.0 40.0 120.0
param gravity 9.81 0.0 20.0
maxtime 4.0
state theta - 0.9
state omega run_speed over pole_length
state flex 0.0
state flexrate run_speed 0.18
eq s sin { theta }
eq c cos { theta }
eq topx pole_length s
eq topy pole_length c
eq midx 0.5 topx + flex c
eq midy 0.5 topy - flex s
derivative theta omega
derivative omega { - gravity over pole_length } s + { stiffness flex } over { mass pole_length pole_length } - 0.08 omega
derivative flex flexrate
derivative flexrate { - stiffness flex } over mass - { damping flexrate } over mass - pole_length omega omega 0.08
point plant 0.0 , 0.0
point pole_middle midx , midy
point pole_top topx , topy
point vaulter_head { topx + 0.3 s } , { topy + 0.3 c }
point vaulter_hip { topx - 0.55 c } , { topy + 0.55 s }
point runway_left - 1.0 , 0.0
point runway_right 1.0 , 0.0
link plant pole_middle
link pole_middle pole_top
link pole_top vaulter_head
link pole_top vaulter_hip
link runway_left plant
link plant runway_right
observable height pole_length c
observable pole_energy 0.5 stiffness flex flex
