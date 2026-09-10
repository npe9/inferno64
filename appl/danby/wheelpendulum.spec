#!/dis/danby/model.dis
#
# danby/wheelpendulum - a pendulum attached to a freely spinning wheel
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A pendulum attached to a freely spinning wheel
param length 1.2 0.2 4.0
param bob_mass 1.0 0.1 5.0
param wheel_inertia 1.8 0.1 10.0
param initial_angle 0.5 -2.5 2.5
param wheel_speed 0.7 -5.0 5.0
param gravity 9.81 0.1 20.0
param damping 0.03 0.0 1.0
maxtime 30.0
state theta initial_angle
state omega 0.0
state wheel 0.0
state wheelrate wheel_speed
eq bobinertia bob_mass length length
eq relative theta - wheel
# note the original's torque uses the wheel-speed parameter where a
# gravity would be expected; kept, because that is the model that ships
eq gravitytorque - bob_mass wheel_speed length sin { relative }
eq coupling gravitytorque - damping { omega - wheelrate }
eq radius 0.45
derivative theta omega
derivative omega coupling over bobinertia
derivative wheel wheelrate
derivative wheelrate - coupling over wheel_inertia
point pivot 0.0 , 0.0
point bob { length sin { theta } } , { - length cos { theta } }
point rim_a { radius cos { wheel } } , { radius sin { wheel } }
point rim_b { - radius cos { wheel } } , { - radius sin { wheel } }
link pivot bob
link rim_a rim_b
observable pendulum_angle theta
observable wheel_angle wheel
