#!/dis/danby/model.dis
#
# danby/skylab - the descent of Skylab
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title The descent of Skylab
sprite rocket
param altitude 120.0 0.0 250.0
param density 0.015 0.0 0.08
param area 74.0 0.0 150.0
param mass 77000.0 0.0 150000.0
param scale_height 28.0 0.0 60.0
param gravity 9.81 0.0 20.0
maxtime 80.0
state x 0.0
state y altitude
state vx 7.6
state vy 0.0
eq alt { y + abs { y } } over 2.0
eq rho density exp { - alt over scale_height }
eq v sqrt { vx vx + vy vy }
eq factor - 0.5 rho 2.2 area v over mass
derivative x vx
derivative y vy
derivative vx factor vx
derivative vy factor vy - gravity 0.001
