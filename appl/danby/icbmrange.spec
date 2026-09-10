#!/dis/danby/model.dis
#
# danby/icbmrange - the range of an ICBM
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title The range of an ICBM
sprite rocket
param speed 2.2 0.0 8.0
param angle 0.78 0.0 1.5
param drag 0.002 0.0 0.02
param scale_height 8.0 0.0 30.0
param gravity_turn 1.0 0.0 2.0
param gravity 9.81 0.0 20.0
maxtime 2000.0
state x 0.0
state y 0.0
state vx speed cos { angle }
state vy speed sin { angle }
# an exponential atmosphere with the density taken at the current
# altitude, which is held at the surface value below the ground
eq alt { y + abs { y } } over 2.0
eq rho exp { - alt over scale_height }
eq v sqrt { vx vx + vy vy }
eq factor - 0.5 rho drag v
derivative x vx
derivative y vy
derivative vx factor vx
derivative vy factor vy - gravity 0.001 gravity_turn
