#!/dis/danby/model.dis
#
# danby/magneticpendulum3d - a magnetic pendulum in three dimensions
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A magnetic pendulum in three dimensions
param initial_x 0.35 -1.5 1.5
param initial_y 0.2 -1.5 1.5
param spring 1.3 0.1 5.0
param damping 0.16 0.0 1.5
param magnet_strength 0.2 0.0 1.5
param spacing 0.8 0.2 1.5
maxtime 35.0
state x initial_x
state y initial_y
state z 0.75
state vx 0.0
state vy 0.0
state vz 0.0
# four magnets a quarter turn apart on the floor, written out
eq d1x spacing - x
eq d1y - y
eq r1 d1x d1x + d1y d1y + z z + 0.05
eq f1 magnet_strength over { r1 sqrt { r1 } }
eq d3x - spacing - x
eq d3y - y
eq r3 d3x d3x + d3y d3y + z z + 0.05
eq f3 magnet_strength over { r3 sqrt { r3 } }
eq d4x - x
eq d4y - spacing - y
eq r4 d4x d4x + d4y d4y + z z + 0.05
eq f4 magnet_strength over { r4 sqrt { r4 } }
eq d2ax - x
eq d2ay spacing - y
eq r2 d2ax d2ax + d2ay d2ay + z z + 0.05
eq f2 magnet_strength over { r2 sqrt { r2 } }
eq dz - z
derivative x vx
derivative y vy
derivative z vz
derivative vx - spring x - damping vx + f1 d1x + f2 d2ax + f3 d3x + f4 d4x
derivative vy - spring y - damping vy + f1 d1y + f2 d2ay + f3 d3y + f4 d4y
derivative vz - spring { z - 0.75 } - damping vz + f1 dz + f2 dz + f3 dz + f4 dz
point bob x , { y - 0.45 z }
point magnet_east spacing , 0.0
point magnet_north 0.0 , spacing
point magnet_west { - spacing } , 0.0
point magnet_south 0.0 , { - spacing }
point floor 0.0 , { - 0.45 1.5 }
link bob floor
observable horizontal_radius sqrt { x x + y y }
observable height z
