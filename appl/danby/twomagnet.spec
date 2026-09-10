#!/dis/danby/model.dis
#
# danby/twomagnet - a two-magnet toy
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A two-magnet toy
param spring 1.0 0.05 8.0
param magnetic_strength 0.35 0.0 5.0
param damping 0.12 0.0 2.0
param magnet_spacing 1.2 0.2 3.0
param height 0.75 0.05 2.0
param initial_x 0.3 -2.0 2.0
maxtime 35.0
state x initial_x
state v 0.0
# the original's loop over the two magnets, written out
eq dxa - magnet_spacing - x
eq r2a dxa dxa + height height
eq dxb magnet_spacing - x
eq r2b dxb dxb + height height
eq pull magnetic_strength dxa over { r2a sqrt { r2a } } + magnetic_strength dxb over { r2b sqrt { r2b } }
derivative x v
derivative v - spring x - damping v + pull
point bob x , height
point magnet_a { - magnet_spacing } , 0.0
point magnet_b magnet_spacing , 0.0
point pivot 0.0 , { 2.0 height }
link bob pivot
observable position x
observable velocity v
