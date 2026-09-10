#!/dis/danby/model.dis
#
# danby/badminton - Shuttlecock trajectories in badminton
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Shuttlecock trajectories in badminton
param speed 55.0 0.0 90.0
param angle 0.18 0.0 1.3
param drag 0.045 0.0 0.12
param lift 0.0 0.0 0.01
param spin 0.0 0.0 100.0
param gravity 9.81 0.0 20.0
maxtime 8.0
state x 0.0
state y 2.2
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift spin vy
derivative vy - gravity - drag v vy + lift spin vx
