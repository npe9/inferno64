#!/dis/danby/model.dis
#
# danby/skijump - the ski jump
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title A model for the ski jump
param takeoff_speed 27.0 0.0 45.0
param ramp_angle 0.12 0.0 0.8
param drag 0.006 0.0 0.03
param lift 0.002 0.0 0.01
param headwind 0.0 0.0 20.0
param gravity 9.81 0.0 20.0
maxtime 10.0
state x 0.0
state y 4.0
state vx takeoff_speed cos { ramp_angle }
state vy takeoff_speed sin { ramp_angle }
# the air moves, so drag and lift act on the speed through the air while
# the jumper still travels over the ground at vx
eq relativevx vx + headwind
eq v sqrt { relativevx relativevx + vy vy }
derivative x vx
derivative y vy
derivative vx - drag v relativevx - lift vy
derivative vy - gravity - drag v vy + lift relativevx
