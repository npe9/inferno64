#!/dis/danby/model.dis
#
# danby/badfootball - A badly kicked football
#
# The whole model is the script below: its parameters and their ranges,
# where the flight starts and how fast, and the accelerations that shape
# it.  danbylab(2) is a library this calls with that script - it owns
# the window, the integrator and the controls, and knows nothing about
# this model.
#
family flight
title A badly kicked football
param speed 24.0 0.0 40.0
param elevation 0.55 0.0 1.3
param aim 0.0 -0.5 0.5
param drag 0.008 0.0 0.03
param wobble 1.5 -4.0 4.0
param gravity 9.81 0.0 20.0
maxtime 8.0
state x 0.0
state lateral 0.0
state height 0.0
state vx speed cos { elevation } cos { aim }
state vy speed cos { elevation } sin { aim }
state vz speed sin { elevation }
eq v sqrt { vx sup 2 + vy sup 2 + vz sup 2 }
derivative x vx
derivative lateral vy
derivative height vz
derivative vx - { drag v vx }
derivative vy - { drag v vy } + wobble sin { 14.0 t }
derivative vz - gravity - drag v vz
