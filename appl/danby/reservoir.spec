#!/dis/danby/model.dis
#
# danby/reservoir - the dynamics of a reservoir system
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Dynamics of a reservoir system
param inflow 0.8 0.0 3.0
param upper_outlet 0.55 0.0 3.0
param lower_outlet 0.4 0.0 3.0
param demand 0.25 0.0 2.0
param evaporation 0.3 0.0 1.0
maxtime 100.0
state upper_reservoir 1.4
state lower_reservoir 0.7
state service_storage 0.35
# Torricelli: an outlet flows as the root of its head, and an empty
# reservoir does not flow at all rather than taking the root of a
# negative number
eq ru { upper_reservoir + abs { upper_reservoir } } over 2.0
eq rl { lower_reservoir + abs { lower_reservoir } } over 2.0
eq rs { service_storage + abs { service_storage } } over 2.0
eq upperflow upper_outlet sqrt { ru }
eq lowerflow lower_outlet sqrt { rl }
eq delivery demand sqrt { rs }
derivative upper_reservoir inflow - upperflow - evaporation upper_reservoir
derivative lower_reservoir upperflow - lowerflow - evaporation lower_reservoir
derivative service_storage lowerflow - delivery - evaporation service_storage
