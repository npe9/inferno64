#!/dis/danby/model.dis
#
# danby/dynamoreversal - a dynamo with magnetic reversal
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A dynamo with magnetic reversal
param electrical_loss 1.0 0.05 5.0
param rotation_asymmetry 1.8 0.0 6.0
param mechanical_drive 1.0 0.0 6.0
param initial_imbalance 0.1 -2.0 2.0
maxtime 80.0
state field_1 1.0 + initial_imbalance
state field_2 0.8 - initial_imbalance
state spin 1.0
derivative field_1 - electrical_loss field_1 + field_2 spin
derivative field_2 - electrical_loss field_2 + { spin - rotation_asymmetry } field_1
derivative spin mechanical_drive - field_1 field_2
point disc_a_bottom - 1.0 , - 0.8
point disc_a_top - 1.0 , 0.8
point disc_b_bottom 1.0 , - 0.8
point disc_b_top 1.0 , 0.8
point coil_a - 1.0 , { field_1 over 3.0 }
point coil_b 1.0 , { field_2 over 3.0 }
link disc_a_bottom disc_a_top
link disc_b_bottom disc_b_top
link coil_a coil_b
observable field_1 field_1
observable field_2 field_2
