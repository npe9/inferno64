#!/dis/danby/model.dis
#
# danby/soccerkick - Kicking a ball in soccer
#
# The whole model is the script below: its parameters and their ranges,
# where the flight starts and how fast, and the accelerations that shape
# it.  danbylab(2) is a library this calls with that script - it owns
# the window, the integrator and the controls, and knows nothing about
# this model.
#
family flight
title Kicking a ball in soccer
param speed 28.0 0.0 45.0
param elevation 0.28 0.0 0.9
param aim 0.0 -0.5 0.5
param drag 0.006 0.0 0.03
param curve 0.018 -0.08 0.08
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
derivative vx - { drag v vx } - curve vy
derivative vy - { drag v vy } + curve vx
derivative vz - gravity - drag v vz
