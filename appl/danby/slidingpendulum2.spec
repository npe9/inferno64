#!/dis/danby/model.dis
#
# danby/slidingpendulum2 - a sliding pendulum on an elastic support
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A sliding pendulum: elastic support
param support_mass 2.0 0.1 10.0
param bob_mass 1.0 0.1 10.0
param length 1.4 0.2 5.0
param initial_angle 0.6 -2.5 2.5
param gravity 9.81 0.1 20.0
param spring 1.8 0.0 10.0
param cart_damping 0.15 0.0 2.0
maxtime 30.0
state x 0.0
state vx 0.0
state theta initial_angle
state omega 0.0
eq s sin { theta }
eq c cos { theta }
eq hinge_damping 0.03
eq den support_mass + bob_mass { s sup 2 }
# the hinge damper is a couple, so its reaction acts on the support too
eq force bob_mass s { length { omega sup 2 } + gravity c } + bob_mass length hinge_damping omega c - spring x - cart_damping vx
eq acc force over den
eq tangential { - acc c - gravity s } over length
derivative x vx
derivative vx acc
derivative theta omega
derivative omega tangential - hinge_damping omega
point support x , 0.0
point bob { x + length s } , { - length c }
point cart_left { x - 0.35 } , 0.0
point cart_right { x + 0.35 } , 0.0
point rail_left - 2.0 , 0.0
point rail_right 2.0 , 0.0
point spring_anchor - 2.0 , 0.0
point spring_end { x - 0.35 } , 0.0
link support bob
link cart_left cart_right
link rail_left rail_right
link spring_anchor spring_end
observable support_position x
observable angle theta
