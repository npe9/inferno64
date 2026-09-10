#!/dis/danby/model.dis
#
# danby/fireworks - fireworks
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Fireworks
param launch_speed 32.0 5.0 60.0
param fuse 1.8 0.2 4.0
param burst_speed 14.0 1.0 30.0
param drag 0.015 0.0 0.08
param gravity 9.81 0.0 20.0
param symmetry 1.0 0.5 1.5
maxtime 8.0
state x0 0.0
state y0 0.0
state vx0 0.0
state vy0 launch_speed
state x1 0.0
state y1 0.0
state vx1 0.0
state vy1 launch_speed
state x2 0.0
state y2 0.0
state vx2 0.0
state vy2 launch_speed
state x3 0.0
state y3 0.0
state vx3 0.0
state vy3 launch_speed
# one sharp push at the fuse time, in four directions a quarter turn
# apart - the original's Gaussian, whose 5.6418958 is 1/sqrt(pi) times
# ten so that the impulse integrates to the burst speed
eq delta t - fuse
eq burst burst_speed 5.6418958 exp { - 100.0 delta delta }
eq a0 { 2.0 PI 0.0 } over 4.0 symmetry
eq a1 { 2.0 PI 1.0 } over 4.0 symmetry
eq a2 { 2.0 PI 2.0 } over 4.0 symmetry
eq a3 { 2.0 PI 3.0 } over 4.0 symmetry
eq s0 sqrt { vx0 vx0 + vy0 vy0 }
eq s1 sqrt { vx1 vx1 + vy1 vy1 }
eq s2 sqrt { vx2 vx2 + vy2 vy2 }
eq s3 sqrt { vx3 vx3 + vy3 vy3 }
derivative x0 vx0
derivative y0 vy0
derivative vx0 burst cos { a0 } - drag s0 vx0
derivative vy0 burst sin { a0 } - gravity - drag s0 vy0
derivative x1 vx1
derivative y1 vy1
derivative vx1 burst cos { a1 } - drag s1 vx1
derivative vy1 burst sin { a1 } - gravity - drag s1 vy1
derivative x2 vx2
derivative y2 vy2
derivative vx2 burst cos { a2 } - drag s2 vx2
derivative vy2 burst sin { a2 } - gravity - drag s2 vy2
derivative x3 vx3
derivative y3 vy3
derivative vx3 burst cos { a3 } - drag s3 vx3
derivative vy3 burst sin { a3 } - gravity - drag s3 vy3
eq hi01 { x0 + x1 + abs { x0 - x1 } } over 2.0
eq hi23 { x2 + x3 + abs { x2 - x3 } } over 2.0
eq xmax { hi01 + hi23 + abs { hi01 - hi23 } } over 2.0
eq lo01 { x0 + x1 - abs { x0 - x1 } } over 2.0
eq lo23 { x2 + x3 - abs { x2 - x3 } } over 2.0
eq xmin { lo01 + lo23 - abs { lo01 - lo23 } } over 2.0
point spark_0 x0 , y0
point spark_1 x1 , y1
point spark_2 x2 , y2
point spark_3 x3 , y3
point ground_left - 2.0 , 0.0
point ground_right 2.0 , 0.0
link ground_left ground_right
observable mean_altitude { y0 + y1 + y2 + y3 } over 4.0
observable spread xmax - xmin
