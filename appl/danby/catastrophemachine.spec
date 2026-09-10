#!/dis/danby/model.dis
#
# danby/catastrophemachine - Zeeman's catastrophe machine
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Zeeman's catastrophe machine
param mass 1.0 0.1 5.0
param spring 2.2 0.1 8.0
param rest_length 1.2 0.2 3.0
param damping 0.25 0.0 2.0
param control_rate 0.22 -2.0 2.0
param initial_x 0.0 -1.5 1.5
maxtime 45.0
state x initial_x
state v 0.0
state control 0.0
eq cx 1.8 cos { control }
eq cy 1.8 sin { control } + 1.0
# each spring pulls along its own line; only the x component moves the disc
eq adx - 1.2 - x
eq ady 1.0
eq ad sqrt { adx adx + ady ady } + 0.000001
eq afx spring { ad - rest_length } adx over ad
eq bdx cx - x
eq bdy cy
eq bd sqrt { bdx bdx + bdy bdy } + 0.000001
eq bfx spring { bd - rest_length } bdx over bd
derivative x v
derivative v { afx + bfx - damping v } over mass
derivative control control_rate
point disc x , 0.0
point fixed_anchor - 1.2 , 1.0
point control_anchor cx , cy
point track_left - 2.0 , 0.0
point track_right 2.0 , 0.0
link disc fixed_anchor
link disc control_anchor
link track_left track_right
observable state x
observable control_x cx
