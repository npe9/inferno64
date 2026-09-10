#!/dis/danby/model.dis
#
# danby/baseballpitch - A model for a baseball pitch
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title A model for a baseball pitch
param speed 40.0 0.0 55.0
param angle -0.03 -0.3 0.3
param drag 0.003 0.0 0.02
param lift 0.0005 0.0 0.003
param spin 180.0 0.0 350.0
param gravity 9.81 0.0 20.0
maxtime 0.55
state x 0.0
state y 1.8
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift spin vy
derivative vy - gravity - drag v vy + lift spin vx
