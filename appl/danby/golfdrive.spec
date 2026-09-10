#!/dis/danby/model.dis
#
# danby/golfdrive - Driving a golf ball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Driving a golf ball
param ball_speed 70.0 0.0 100.0
param launch_angle 0.22 0.0 0.8
param drag 0.004 0.0 0.02
param lift 0.00055 0.0 0.003
param backspin 250.0 0.0 500.0
param gravity 9.81 0.0 20.0
maxtime 15.0
state x 0.0
state y 0.0
state vx ball_speed cos { launch_angle }
state vy ball_speed sin { launch_angle }
eq v sqrt { vx vx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v vx - lift backspin vy
derivative vy - gravity - drag v vy + lift backspin vx
