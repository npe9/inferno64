#!/dis/danby/model.dis
#
# danby/basketball - Shooting in basketball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Shooting in basketball
param speed 8.5 0.0 16.0
param angle 0.85 0.0 1.45
param drag 0.001 0.0 0.02
param lift 0.00015 0.0 0.003
param backspin 20.0 0.0 100.0
param gravity 9.81 0.0 20.0
maxtime 3.0
state x 0.0
state y 2.0
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift backspin vy
derivative vy - gravity - drag v vy + lift backspin vx
