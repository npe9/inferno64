#!/dis/danby/model.dis
#
# danby/bungee - a bungee jump
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A bungee jump
param cord_length 18.0 2.0 40.0
param stiffness 55.0 5.0 180.0
param mass 45.0 25.0 120.0
param damping 12.0 0.0 60.0
param air_drag 0.8 0.0 5.0
param gravity 9.81 0.0 20.0
maxtime 25.0
state distance 0.0
state speed 0.0
# the cord pulls only once it is taut, and only then does its damper act
eq slack distance - cord_length
eq extension { slack + abs { slack } } over 2.0
eq taut step { slack }
eq cordforce stiffness extension + taut damping speed
derivative distance speed
derivative speed gravity - { cordforce + air_drag speed } over mass
point platform 0.0 , 0.0
point jumper 0.0 , { - distance }
point rail_left - 0.6 , 0.0
point rail_right 0.6 , 0.0
link platform jumper spring
link rail_left rail_right
observable fall_distance distance
observable speed speed
