#!/dis/danby/model.dis
#
# danby/rocketintro - the motion of a rocket, to begin with
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The motion of a rocket: introduction
param thrust 2500.0 0.0 8000.0
param dry_mass 80.0 10.0 300.0
param propellant 120.0 0.0 500.0
param mass_flow 5.0 0.2 20.0
param drag 0.02 0.0 0.1
param gravity 9.81 0.0 20.0
maxtime 40.0
state altitude 0.0
state speed 0.0
# The engine burns while there is propellant left, and the propellant
# still aboard is clamped at zero - so the denominator never drops below
# the dry mass, and the thrust term is exactly zero after burnout.
# ("aboard", not "left": left is an eqn delimiter keyword.)
eq remaining propellant - mass_flow t
eq burning step { remaining }
eq aboard { remaining + abs { remaining } } over 2.0
eq acceleration burning { thrust over { dry_mass + aboard } }
derivative altitude speed
derivative speed acceleration - gravity - drag speed abs { speed }
point base 0.0 , altitude
point nose 0.0 , { altitude + 1.0 }
point fin_left - 0.35 , altitude
point fin_right 0.35 , altitude
link base nose
link base fin_left
link base fin_right
observable altitude altitude
observable speed speed
