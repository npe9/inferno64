#!/dis/danby/model.dis
#
# danby/rotatingring2 - a ball in a rotating circular ring, with the ring free
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A ball in a rotating circular ring: free ring
param radius 1.0 0.2 4.0
param gravity 9.81 0.1 20.0
param ball_mass 1.0 0.1 5.0
param ring_inertia 1.2 0.1 10.0
param angular_momentum 3.0 0.0 12.0
param damping 0.03 0.0 1.0
param initial_angle 0.45 -3.0 3.0
maxtime 35.0
state theta initial_angle
state omega 0.0
state spin 0.0
eq s sin { theta }
eq c cos { theta }
# the ring is free, so its rate follows from conserved angular momentum
eq rate angular_momentum over { ring_inertia + ball_mass radius radius s s }
eq width 0.35 + 0.65 abs { cos { spin } }
eq halfspan width radius
derivative theta omega
derivative omega rate rate s c - gravity s over radius - damping omega
derivative spin rate
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
observable ring_speed rate
