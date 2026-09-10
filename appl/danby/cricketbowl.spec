#!/dis/danby/model.dis
#
# danby/cricketbowl - Bowling a cricket ball
#
# The whole model is the script below: its parameters and their ranges,
# where the flight starts and how fast, and the accelerations that shape
# it.  danbylab(2) is a library this calls with that script - it owns
# the window, the integrator and the controls, and knows nothing about
# this model.
#
family flight
title Bowling a cricket ball
param speed 34.0 0.0 50.0
param elevation 0.03 -0.35 0.35
param aim 0.0 -0.35 0.35
param drag 0.004 0.0 0.02
param spin 0.012 -0.06 0.06
param gravity 9.81 0.0 20.0
maxtime 1.2
state x 0.0
state lateral 0.0
state height 2.0
state vx speed cos { elevation } cos { aim }
state vy speed cos { elevation } sin { aim }
state vz speed sin { elevation }
eq v sqrt { vx sup 2 + vy sup 2 + vz sup 2 }
derivative x vx
derivative lateral vy
derivative height vz
derivative vx - { drag v vx } - spin vy
derivative vy - { drag v vy } + spin vx
derivative vz - gravity - drag v vz
