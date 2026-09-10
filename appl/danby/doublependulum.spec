#!/dis/danby/model.dis
#
# danby/doublependulum - a double pendulum
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A double pendulum
param mass_1 1.0 0.1 5.0
param mass_2 1.0 0.1 5.0
param length_1 1.0 0.2 3.0
param length_2 1.0 0.2 3.0
param angle_1 1.1 -3.0 3.0
param angle_2 1.6 -3.0 3.0
param gravity 9.81 0.1 20.0
param damping 0.01 0.0 0.5
maxtime 30.0
state a1 angle_1
state w1 0.0
state a2 angle_2
state w2 0.0
eq delta a1 - a2
eq cd cos { delta }
eq sd sin { delta }
eq den 2.0 mass_1 + mass_2 - mass_2 cos { 2.0 delta }
eq num1 - gravity { 2.0 mass_1 + mass_2 } sin { a1 } - mass_2 gravity sin { a1 - 2.0 a2 } - 2.0 sd mass_2 { w2 w2 length_2 + w1 w1 length_1 cd }
eq num2 2.0 sd { w1 w1 length_1 { mass_1 + mass_2 } + gravity { mass_1 + mass_2 } cos { a1 } + w2 w2 length_2 mass_2 cd }
eq x1 length_1 sin { a1 }
eq y1 - length_1 cos { a1 }
eq x2 x1 + length_2 sin { a2 }
eq y2 y1 - length_2 cos { a2 }
derivative a1 w1
derivative w1 num1 over { length_1 den } - damping w1
derivative a2 w2
derivative w2 num2 over { length_2 den } - damping w2
point pivot 0.0 , 0.0
point bob_1 x1 , y1
point bob_2 x2 , y2
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link pivot bob_1
link bob_1 bob_2
link rail_left rail_right
observable angle_1 a1
observable angle_2 a2
