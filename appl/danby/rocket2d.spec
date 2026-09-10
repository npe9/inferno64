#!/dis/danby/model.dis
#
# danby/rocket2d - the two-dimensional motion of a rocket
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title The motion of a rocket: two-dimensional motion
sprite rocket
param thrust 3800.0 0.0 10000.0
param pitch 1.35 0.0 1.57
param dry_mass 80.0 0.0 300.0
param propellant 140.0 0.0 500.0
param flow 6.0 0.0 20.0
param gravity 9.81 0.0 20.0
maxtime 80.0
state x 0.0
state y 0.0
state vx 0.0
state vy 0.0
# the engine burns while there is propellant left, and the mass aboard is
# clamped at zero so the denominator never drops below the dry mass
eq remaining propellant - flow t
eq burning step { remaining }
eq aboard { remaining + abs { remaining } } over 2.0
eq wet dry_mass + aboard
eq acceleration burning { thrust over wet }
eq alt { y + abs { y } } over 2.0
eq rho exp { - alt over 8.0 }
eq v sqrt { vx vx + vy vy }
eq factor - 0.5 rho 0.02 v over wet
derivative x vx
derivative y vy
derivative vx acceleration cos { pitch } + factor vx
derivative vy acceleration sin { pitch } + factor vy - gravity
