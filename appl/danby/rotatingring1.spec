#!/dis/danby/model.dis
#
# danby/rotatingring1 - a ball in a rotating circular ring, at a prescribed speed
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A ball in a rotating circular ring: prescribed speed
param radius 1.0 0.2 4.0
param gravity 9.81 0.1 20.0
param ring_speed 2.6 0.0 8.0
param damping 0.08 0.0 2.0
param initial_angle 0.35 -3.0 3.0
maxtime 35.0
state theta initial_angle
state omega 0.0
state spin 0.0
eq s sin { theta }
eq c cos { theta }
eq width 0.35 + 0.65 abs { cos { spin } }
eq halfspan width radius
derivative theta omega
derivative omega ring_speed ring_speed s c - gravity s over radius - damping omega
derivative spin ring_speed
point ring_left - halfspan , 0.0
point ring_bottom 0.0 , - radius
point ring_right halfspan , 0.0
point ring_top 0.0 , radius
point ball { halfspan s } , { - radius c }
link ring_left ring_bottom
link ring_bottom ring_right
link ring_right ring_top
link ring_top ring_left
observable ball_angle theta
observable angular_speed omega
