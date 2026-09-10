#!/dis/danby/model.dis
#
# danby/spinningball - Dynamics of a spinning ball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Dynamics of a spinning ball
param speed 35.0 0.0 80.0
param angle 0.55 0.0 1.5
param drag 0.006 0.0 0.03
param lift 0.0008 0.0 0.004
param spin 150.0 0.0 400.0
param gravity 9.81 0.0 20.0
maxtime 30.0
state x 0.0
state y 0.0
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift spin vy
derivative vy - gravity - drag v vy + lift spin vx
