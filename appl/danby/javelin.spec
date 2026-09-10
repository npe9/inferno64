#!/dis/danby/model.dis
#
# danby/javelin - Motion of a javelin
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Motion of a javelin
param speed 29.0 0.0 45.0
param angle 0.62 0.0 1.3
param drag 0.004 0.0 0.03
param lift 0.005 0.0 0.03
param attitude 1.0 0.0 1.5
param gravity 9.81 0.0 20.0
maxtime 10.0
state x 0.0
state y 2.0
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift attitude vy
derivative vy - gravity - drag v vy + lift attitude vx
