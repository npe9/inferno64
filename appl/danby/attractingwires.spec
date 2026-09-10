#!/dis/danby/model.dis
#
# danby/attractingwires - two attracting current-carrying wires
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Two attracting current-carrying wires
param mass 1.0 0.1 5.0
param support_spring 1.0 0.05 8.0
param current_force 0.35 0.0 5.0
param rest_spacing 2.0 0.4 4.0
param damping 0.12 0.0 2.0
param initial_spacing 1.4 0.15 4.0
maxtime 25.0
state spacing initial_spacing
state closing 0.0
eq d { spacing + 0.05 + abs { spacing - 0.05 } } over 2.0
eq h spacing over 2.0
derivative spacing closing
derivative closing { support_spring { rest_spacing - d } - current_force over d - damping closing } over mass
point wire_a_bottom { - h } , - 1.2
point wire_a_top { - h } , 1.2
point wire_b_bottom h , - 1.2
point wire_b_top h , 1.2
point bench_left - 2.0 , 0.0
point bench_right 2.0 , 0.0
link wire_a_bottom wire_a_top
link wire_b_bottom wire_b_top
link bench_left bench_right
observable wire_spacing spacing
observable closing_speed closing
