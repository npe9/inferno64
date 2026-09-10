#!/dis/danby/model.dis
#
# danby/slidingpendulum1 - a sliding pendulum on a free support.
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about pendulums.
#
family mechanism
title A sliding pendulum: free support
param support_mass 2.0 0.1 10.0
param bob_mass 1.0 0.1 10.0
param length 1.4 0.2 5.0
param initial_angle 0.6 -2.5 2.5
param gravity 9.81 0.1 20.0
param hinge_damping 0.04 0.0 1.0
maxtime 30.0
state x 0.0
state vx 0.0
state theta initial_angle
state omega 0.0
eq s sin { theta }
eq c cos { theta }
# M + m sin^2(theta): the effective mass the bob swings against
eq den support_mass + bob_mass { s sup 2 }
# the hinge damper is a couple, so its reaction acts on the support
# too - the term that was missing until 242e399d
eq force bob_mass s { length { omega sup 2 } + gravity c } + bob_mass length hinge_damping omega c
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
link support bob
link cart_left cart_right
link rail_left rail_right
observable support_position x
observable angle theta
