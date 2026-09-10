#!/dis/danby/model.dis
#
# danby/magneticpendulum2d - a magnetic pendulum in two dimensions
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A magnetic pendulum in two dimensions
param initial_x 0.35 -1.5 1.5
param spring 1.2 0.1 5.0
param damping 0.18 0.0 1.5
param magnet_strength 0.16 0.0 1.0
param spacing 0.75 0.2 1.5
maxtime 35.0
state x initial_x
state y 0.24
state vx 0.0
state vy 0.0
# three magnets at a third of a turn apart, written out
eq m1x spacing
eq m1y 0.0
eq m2x - 0.5 spacing
eq m2y 0.86602540378443864676 spacing
eq m3x - 0.5 spacing
eq m3y - 0.86602540378443864676 spacing
eq d1x m1x - x
eq d1y m1y - y
eq r1 d1x d1x + d1y d1y + 0.06
eq f1 magnet_strength over { r1 sqrt { r1 } }
eq d2x m2x - x
eq d2y m2y - y
eq r2 d2x d2x + d2y d2y + 0.06
eq f2 magnet_strength over { r2 sqrt { r2 } }
eq d3x m3x - x
eq d3y m3y - y
eq r3 d3x d3x + d3y d3y + 0.06
eq f3 magnet_strength over { r3 sqrt { r3 } }
derivative x vx
derivative y vy
derivative vx - spring x - damping vx + f1 d1x + f2 d2x + f3 d3x
derivative vy - spring y - damping vy + f1 d1y + f2 d2y + f3 d3y
point bob x , y
point magnet_1 spacing , 0.0
point magnet_2 { - 0.5 spacing } , { 0.8660254 spacing }
point magnet_3 { - 0.5 spacing } , { - 0.8660254 spacing }
point centre 0.0 , 0.0
link bob centre
observable x x
observable y y
