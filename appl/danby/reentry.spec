#!/dis/danby/model.dis
#
# danby/reentry - reentering the Earth's atmosphere
#
# The whole model is the script below: its parameters and their ranges,
# where it is launched from and how fast, and the accelerations that
# shape the flight.  danbylab(2) is a library this calls with that script
# - it owns the window, the integrator and the controls, and knows
# nothing about this model.
#
family trajectory
title Reentering the Earth's atmosphere
sprite rocket
param speed 7.8 0.0 12.0
param entry_angle -0.1 -0.5 0.5
param ballistic_coefficient 0.018 0.0 0.08
param lift 4.0 0.0 12.0
param scale_height 8.0 0.0 20.0
param gravity 9.81 0.0 20.0
maxtime 300.0
state x 0.0
state y 120.0
state vx speed cos { entry_angle }
state vy speed sin { entry_angle }
eq alt { y + abs { y } } over 2.0
eq rho exp { - alt over scale_height }
eq v sqrt { vx vx + vy vy }
eq factor - 0.5 rho ballistic_coefficient v
# lift acts across the flight path, so it is the velocity turned a
# quarter turn and scaled; at a standstill there is no path to be across
# and the term is dropped, which is what the original's speed test did
eq moving step { v }
eq unit v + 1.0 - moving
derivative x vx
derivative y vy
derivative vx factor vx - moving lift vy 0.001 over unit
derivative vy factor vy + moving lift vx 0.001 over unit - gravity 0.001
