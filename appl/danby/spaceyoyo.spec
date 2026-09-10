#!/dis/danby/model.dis
#
# danby/spaceyoyo - de-spinning a satellite with a space yo-yo
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title De-spinning a satellite: a space yo-yo
param tether_length 3.0 0.5 10.0
param tip_mass 0.8 0.05 5.0
param satellite_inertia 12.0 1.0 50.0
param initial_spin 80.0 -200.0 200.0
param damping 0.12 0.0 1.0
param deployment 1.2 0.1 5.0
maxtime 20.0
state angle 0.0
state spin initial_spin
state radius 0.05
state radialspeed deployment
eq totalinertia satellite_inertia + 2.0 tip_mass radius radius
eq angularmomentum { satellite_inertia + 2.0 tip_mass 0.05 0.05 } initial_spin
# the tether stops paying out at full length, and only while going out
eq stopped { 1.0 - step { tether_length - radius } } step { radialspeed }
eq c cos { angle }
eq s sin { angle }
derivative angle angularmomentum over totalinertia
derivative spin - damping spin - { 4.0 tip_mass radius radialspeed spin } over totalinertia
derivative radius radialspeed
derivative radialspeed radius spin spin - 0.4 radialspeed - stopped 12.0 { radius - tether_length }
point hub 0.0 , 0.0
point tip_a { radius c } , { radius s }
point tip_b { - radius c } , { - radius s }
point body_a { - 0.4 s } , { 0.4 c }
point body_b { 0.4 s } , { - 0.4 c }
link hub tip_a string
link hub tip_b string
link body_a body_b
observable spin spin
observable deployment radius
