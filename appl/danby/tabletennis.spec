#!/dis/danby/model.dis
#
# danby/tabletennis - table tennis
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Table tennis
param speed 12.0 0.0 30.0
param angle 0.08 0.0 0.8
param drag 0.018 0.0 0.06
param lift 0.0015 0.0 0.006
param topspin 90.0 0.0 250.0
param gravity 9.81 0.0 20.0
maxtime 2.0
state x 0.0
state y 1.0
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
# topspin, so the Magnus force is the other way round from a backspun
# ball: the lift enters with the opposite sign
derivative x vx
derivative y vy
derivative vx - drag v vx + lift topspin vy
derivative vy - gravity - drag v vy - lift topspin vx
