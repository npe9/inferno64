#!/dis/danby/model.dis
#
# danby/duffing - Duffing's equation
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Duffing's equation
param damping 0.25 0.0 2.0
param linear -1.0 -3.0 3.0
param cubic 1.0 -3.0 3.0
param drive 0.3 0.0 3.0
param frequency 1.2 0.1 5.0
param initial_x 0.2 -3.0 3.0
maxtime 60.0
state x initial_x
state v 0.0
derivative x v
derivative v drive cos { frequency t } - damping v - linear x - cubic x x x
point wall - 2.0 , 0.0
# The wall pins the left of the view and nothing pinned the right,
# so the box's right edge was the mass itself and the mass sat at
# the same spot on screen however far it swung.  This pins the
# right; `plain' means it contributes the frame and no sprite.
point stop 2.0 , 0.0
point mass x , 0.0
point mass_top x , - 0.3
point mass_bottom x , 0.3
link wall mass
link mass_top mass_bottom
observable displacement x
observable velocity v
plain stop
