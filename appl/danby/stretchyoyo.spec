#!/dis/danby/model.dis
#
# danby/stretchyoyo - de-spinning a satellite with a stretch yo-yo
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title De-spinning a satellite: the stretch yo-yo
param rest_length 3.0 0.5 10.0
param tip_mass 0.8 0.05 5.0
param satellite_inertia 12.0 1.0 50.0
param initial_spin 80.0 -200.0 200.0
param stiffness 18.0 1.0 80.0
param damping 0.7 0.0 4.0
maxtime 25.0
state angle 0.0
state spin initial_spin
state radius 0.7 rest_length
state radialspeed 0.0
eq inertia satellite_inertia + 2.0 tip_mass radius radius
eq c cos { angle }
eq s sin { angle }
derivative angle spin
derivative spin { - 4.0 tip_mass radius radialspeed spin } over inertia
derivative radius radialspeed
derivative radialspeed radius spin spin - { stiffness { radius - rest_length } } over tip_mass - damping radialspeed
point hub 0.0 , 0.0
point tip_a { radius c } , { radius s }
point tip_b { - radius c } , { - radius s }
point body_a { - 0.4 s } , { 0.4 c }
point body_b { 0.4 s } , { - 0.4 c }
link hub tip_a string
link hub tip_b string
link body_a body_b
observable spin spin
observable stretch radius - rest_length
