#!/dis/danby/model.dis
#
# danby/yoyo - a model for the motion of a yo-yo
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A model for the motion of a yo-yo
param string_length 1.2 0.2 3.0
param axle_radius 0.04 0.01 0.15
param mass 0.12 0.03 0.5
param inertia 0.08 0.005 0.3
param friction 0.02 0.0 0.2
param gravity 9.81 0.0 20.0
maxtime 8.0
state depth 0.0
state speed 0.0
state spin 0.0
eq effectivemass mass + inertia over { axle_radius axle_radius }
eq freefall { mass gravity - friction speed } over effectivemass
# At the end of the string, going down, the yo-yo turns round.
# "depth >= length" is 1 - step(length - depth): step is zero AT
# zero, so its complement is the >= that the original tests, exactly
# and not within an epsilon of it.
eq caught { 1.0 - step { string_length - depth } } step { speed }
eq acceleration { 1.0 - caught } freefall - caught 0.8 gravity
derivative depth speed
derivative speed acceleration
derivative spin speed over axle_radius
point hand 0.0 , 0.0
point axle 0.0 , { - depth }
point rim_a { 0.25 sin { spin } } , { - depth }
point rim_b { - 0.25 sin { spin } } , { - depth }
link hand axle string
link rim_a rim_b
observable depth depth
observable angular_speed speed over axle_radius
