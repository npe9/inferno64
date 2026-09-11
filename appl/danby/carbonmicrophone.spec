#!/dis/danby/model.dis
#
# danby/carbonmicrophone - a carbon microphone circuit
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A carbon microphone circuit
param diaphragm_mass 1.0 0.1 5.0
param stiffness 18.0 0.5 60.0
param mechanical_damping 0.35 0.0 4.0
param bias_voltage 1.5 0.0 8.0
param base_resistance 4.0 0.2 12.0
param resistance_coupling 0.8 -3.0 3.0
param inductance 0.5 0.05 5.0
maxtime 20.0
state x 0.12
state v 0.0
state current 0.0
# the granules never conduct perfectly, so the resistance is held off zero
eq raw base_resistance { 1.0 - resistance_coupling x }
eq resistance { raw + 0.05 + abs { raw - 0.05 } } over 2.0
eq force 0.08 current current
derivative x v
derivative v { - stiffness x - mechanical_damping v + force } over diaphragm_mass
derivative current { bias_voltage - resistance current } over inductance
point fixed_bottom - 1.5 , - 0.8
point fixed_top - 1.5 , 0.8
point plate_bottom x , - 0.8
point plate_top x , 0.8
point lead_in - 1.5 , 0.0
# The fixed plate pinned the left of the view and the moving one was
# the right edge of it, so the diaphragm never appeared to move.
point stop 1.5 , 0.0
point lead_out x , 0.0
link fixed_bottom fixed_top
link plate_bottom plate_top
link lead_in lead_out
observable diaphragm x
observable current current
plain stop
