#!/dis/danby/model.dis
#
# danby/venushead - on Venus, could you see the back of your head?
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title On Venus, could you see the back of your head?
param planet_radius 1.0 0.5 3.0
param density_gradient 0.08 0.0 0.5
param ray_angle 0.25 -1.2 1.2
param eye_height 1.7 0.1 3.0
param curvature 0.2 0.0 1.5
param light_speed 1.0 0.2 2.0
maxtime 12.0
state r planet_radius + 0.05 eye_height
state wrapped 0.0
state bend curvature
state heading ray_angle
eq s sin { heading }
eq c cos { heading }
derivative r light_speed c
derivative wrapped { light_speed s } over r
derivative bend 0.0
derivative heading density_gradient s - { light_speed s } over r
point limb_west { - planet_radius } , 0.0
point limb_south 0.0 , { - planet_radius }
point limb_east planet_radius , 0.0
point limb_north 0.0 , planet_radius
point ray { r cos { wrapped } } , { r sin { wrapped } }
point observer planet_radius , 0.0
point head { planet_radius + 0.15 } , 0.0
link limb_west limb_south
link limb_south limb_east
link limb_east limb_north
link limb_north limb_west
link ray observer
link observer head
observable ray_radius r
observable wrapped_angle wrapped
