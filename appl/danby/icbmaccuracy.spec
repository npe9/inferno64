#!/dis/danby/model.dis
#
# danby/icbmaccuracy - The accuracy of an ICBM
#
# The whole model is the script below: its parameters and their ranges,
# where the flight starts and how fast, and the accelerations that shape
# it.  danbylab(2) is a library this calls with that script - it owns
# the window, the integrator and the controls, and knows nothing about
# this model.
#
family flight
title The accuracy of an ICBM
sprite rocket
param speed 2.2 0.2 8.0
param elevation 0.78 0.1 1.5
param aim_error 0.0 -0.12 0.12
param drag 0.002 0.0 0.02
param crosswind 0.003 -0.02 0.02
param gravity 9.81 0.0 20.0
maxtime 2000.0
state x 0.0
state lateral 0.0
state height 0.0
state vx speed cos { elevation } cos { aim_error }
state vy speed cos { elevation } sin { aim_error }
state vz speed sin { elevation }
eq alt height step { height }
eq rho exp { - { alt over 8.0 } }
eq sp sqrt { vx sup 2 + vz sup 2 }
eq factor - { 0.5 rho drag sp }
derivative x vx
derivative lateral vy
derivative height vz
derivative vx factor vx
derivative vy crosswind - 0.01 vy
derivative vz factor vz - 0.001 gravity
