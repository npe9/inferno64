#!/dis/danby/model.dis
#
# danby/softballpitch - Pitching a softball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Pitching a softball
param speed 28.0 0.0 40.0
param angle 0.04 0.0 0.4
param drag 0.006 0.0 0.03
param lift 0.001 0.0 0.004
param spin 130.0 0.0 300.0
param gravity 9.81 0.0 20.0
maxtime 0.8
state x 0.0
state y 0.7
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift spin vy
derivative vy - gravity - drag v vy + lift spin vx
