#!/dis/danby/model.dis
#
# danby/discus - Path of a discus
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Path of a discus
param speed 25.0 0.0 40.0
param angle 0.6 0.0 1.3
param drag 0.008 0.0 0.04
param lift 0.012 0.0 0.04
param attitude 1.0 0.0 1.5
param gravity 9.81 0.0 20.0
maxtime 10.0
state x 0.0
state y 1.7
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift attitude vy
derivative vy - gravity - drag v vy + lift attitude vx
