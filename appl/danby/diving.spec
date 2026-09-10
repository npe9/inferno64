#!/dis/danby/model.dis
#
# danby/diving - diving
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Diving
param takeoff 5.5 0.0 12.0
param angle 0.85 0.0 1.5
param angular_momentum 4.0 -10.0 10.0
param tuck 0.35 0.1 1.0
param drag 0.025 0.0 0.1
param gravity 9.81 0.0 20.0
maxtime 3.0
state x 0.0
state y 3.0
state vx takeoff cos { angle }
state vy takeoff sin { angle }
state theta 0.0
# an initial value may use the parameters and nothing else - eq lines are
# evaluated per step, not at reset - so the tucked inertia is written out
state spin angular_momentum over { 0.15 + 0.85 tuck }
eq speed sqrt { vx vx + vy vy }
eq length 0.7 + 0.9 tuck
eq dx length sin { theta }
eq dy length cos { theta }
derivative x vx
derivative y vy
derivative vx - drag speed vx
derivative vy - gravity - drag speed vy
derivative theta spin
derivative spin - 0.08 spin
point board_back - 1.2 , 3.0
point board_tip - 0.2 , 3.0
point hips x , y
point head { x + 0.5 dx } , { y + 0.5 dy }
point feet { x - 0.5 dx } , { y - 0.5 dy }
point arm_a { x + 0.35 dy } , { y - 0.35 dx }
point arm_b { x - 0.35 dy } , { y + 0.35 dx }
link board_back board_tip
link head hips
link hips feet
link hips arm_a
link hips arm_b
observable height y
observable rotations theta over { 2.0 PI }
