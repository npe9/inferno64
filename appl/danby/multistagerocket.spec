#!/dis/danby/model.dis
#
# danby/multistagerocket - the motion of a multi-stage rocket
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The motion of a rocket: multi-stage rockets
param stage_1_thrust 4200.0 100.0 10000.0
param stage_1_fuel 180.0 10.0 500.0
param stage_2_fuel 140.0 10.0 400.0
param flow 7.0 0.5 25.0
param stage_2_thrust 2200.0 100.0 8000.0
param gravity 9.81 0.0 20.0
maxtime 60.0
# Two burns, one after the other, then nothing.  step() picks the window;
# the fuel actually consumed is clamped into that window's own range, so
# each denominator stays positive outside it and the whole term is zero
# there anyway.
eq firstburn stage_1_fuel over flow
eq burned flow t
eq in1 step { firstburn - t }
eq in2 { 1.0 - in1 } step { firstburn + { stage_2_fuel over flow } - t }
eq used1 { burned + stage_1_fuel - abs { burned - stage_1_fuel } } over 2.0
eq raised burned - stage_1_fuel
eq lifted { raised + abs { raised } } over 2.0
eq used2 { lifted + stage_2_fuel - abs { lifted - stage_2_fuel } } over 2.0
eq acc1 in1 stage_1_thrust over { 60.0 + stage_1_fuel + stage_2_fuel - used1 }
eq acc2 in2 stage_2_thrust over { 25.0 + stage_2_fuel - used2 }
state altitude 0.0
state speed 0.0
derivative altitude speed
derivative speed acc1 + acc2 - gravity - 0.008 speed abs { speed }
point base 0.0 , altitude
point nose 0.0 , { altitude + 1.4 }
point fin_left - 0.4 , altitude
point fin_right 0.4 , altitude
link base nose
link base fin_left
link base fin_right
observable altitude altitude
observable speed speed
