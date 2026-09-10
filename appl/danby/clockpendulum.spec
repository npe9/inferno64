#!/dis/danby/model.dis
#
# danby/clockpendulum - the pendulum of a clock
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The pendulum of a clock
param length 1.0 0.1 4.0
param initial_angle 0.45 -2.0 2.0
param damping 0.08 0.0 1.0
param gravity 9.81 0.1 20.0
param escapement_width 0.04 0.005 0.4
param impulse 0.18 0.0 2.0
maxtime 40.0
state theta initial_angle
state omega 0.0
eq s sin { theta }
eq c cos { theta }
eq bobx length s
eq boby - length c
# The escapement fires only while the bob is inside the window, and in
# whichever direction it is already going - counting a bob exactly at
# rest as going forwards, as the clock does.
eq inside step { escapement_width - abs { theta } }
eq forward 1.0 - 2.0 step { - omega }
eq escapement impulse inside forward
derivative theta omega
derivative omega { - gravity s } over length - damping omega + escapement
point pivot 0.0 , 0.0
point bob bobx , boby
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
point bob_left { bobx - 0.22 } , boby
point bob_right { bobx + 0.22 } , boby
link pivot bob
link rail_left rail_right
link bob_left bob_right
observable angle theta
observable energy { 0.5 { length sup 2 } { omega sup 2 } } + { gravity length { 1.0 - c } }
