#!/dis/danby/model.dis
#
# danby/projectile - Ballistics: a plain projectile with drag
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Ballistics: a plain projectile with drag
param speed 20.0 0.0 40.0
param angle 0.79 0.0 1.57
param drag 0.005 0.0 0.02
param lift 0.0 0.0 0.01
param spin 0.0 0.0 20.0
param gravity 9.81 0.0 20.0
maxtime 10.0
state x 0.0
state y 0.0
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift spin vy
derivative vy - gravity - drag v vy + lift spin vx
