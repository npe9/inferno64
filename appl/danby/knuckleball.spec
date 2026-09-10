#!/dis/danby/model.dis
#
# danby/knuckleball - pitching a knuckleball
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Pitching a knuckleball
param speed 32.0 0.0 50.0
param angle -0.02 -0.3 0.3
param drag 0.004 0.0 0.02
param flutter 1.4 0.0 4.0
param frequency 48.0 0.0 100.0
param gravity 9.81 0.0 20.0
maxtime 0.65
state x 0.0
state y 1.8
state vx speed cos { angle }
state vy speed sin { angle }
eq v sqrt { vx vx + vy vy }
# a knuckleball has no spin at all; what moves it sideways is the seams
# catching the air, which the model puts in as a vertical force that
# changes sign several times over the pitch
eq sideways flutter sin { frequency t }
derivative x vx
derivative y vy
derivative vx - drag v vx
derivative vy - gravity - drag v vy + sideways
