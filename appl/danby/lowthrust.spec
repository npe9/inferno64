#!/dis/danby/model.dis
#
# danby/lowthrust - low-thrust orbits
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.
#
family orbit
title The motion of a rocket: low-thrust orbits
param initial_radius 1.0 0.5 2.0
param thrust 0.006 -0.02 0.02
param gravity 1.0 0.2 2.0
param steering_offset 0.0 -1.57 1.57
param initial_speed 1.0 0.2 2.0
param softening 0.002 0.0002 0.02
maxtime 80.0
body planet 1.0
body craft 0.0
state xP 0.0
state yP 0.0
state vxP 0.0
state vyP 0.0
state xC initial_radius
state yC 0.0
state vxC 0.0
state vyC initial_speed
# the planet is held fixed; the thrust points along the craft's own
# velocity turned by the steering offset, and there is no direction to
# point along at a standstill, which is what the original's speed test
# meant
eq r sqrt { xC xC + yC yC + softening softening }
eq v sqrt { vxC vxC + vyC vyC }
eq moving step { v }
eq unit v + 1.0 - moving
eq tx moving thrust { cos { steering_offset } vxC - sin { steering_offset } vyC } over unit
eq ty moving thrust { sin { steering_offset } vxC + cos { steering_offset } vyC } over unit
derivative xP 0.0
derivative yP 0.0
derivative vxP 0.0
derivative vyP 0.0
derivative xC vxC
derivative yC vyC
derivative vxC { - gravity xC } over { r r r } + tx
derivative vyC { - gravity yC } over { r r r } + ty
observable radius sqrt { xC xC + yC yC }
observable speed v
