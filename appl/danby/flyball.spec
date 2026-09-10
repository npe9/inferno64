#!/dis/danby/model.dis
#
# danby/flyball - Flight of a fly ball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Flight of a fly ball
param exit_speed 45.0 0.0 70.0
param angle 0.8 0.0 1.4
param drag 0.005 0.0 0.02
param lift 0.00045 0.0 0.003
param backspin 130.0 0.0 350.0
param gravity 9.81 0.0 20.0
maxtime 12.0
state x 0.0
state y 1.0
state vx exit_speed cos { angle }
state vy exit_speed sin { angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift backspin vy
derivative vy - gravity - drag v vy + lift backspin vx
