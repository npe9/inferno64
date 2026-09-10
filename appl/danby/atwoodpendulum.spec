#!/dis/danby/model.dis
#
# danby/atwoodpendulum - the swinging Atwood machine
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The swinging Atwood machine
param swinging_mass 1.0 0.1 8.0
param counterweight 1.6 0.1 8.0
param initial_radius 2.0 0.3 5.0
param initial_angle 0.45 -2.5 2.5
param gravity 9.81 0.1 20.0
param damping 0.03 0.0 1.0
maxtime 25.0
state radius initial_radius
state radialspeed 0.0
state theta initial_angle
state omega 0.0
eq r { radius + 0.08 + abs { radius - 0.08 } } over 2.0
eq radialaccel { swinging_mass r omega omega + swinging_mass gravity cos { theta } - counterweight gravity - damping radialspeed } over { swinging_mass + counterweight }
eq countery - { 2.0 initial_radius - r }
derivative radius radialspeed
derivative radialspeed radialaccel
derivative theta omega
derivative omega { - { gravity sin { theta } + 2.0 radialspeed omega } } over r
point pulley_a 0.0 , 0.0
point bob { r sin { theta } } , { - r cos { theta } }
point pulley_b 0.5 , 0.0
point weight 0.5 , countery
point beam_left - 0.25 , 0.0
point beam_right 0.75 , 0.0
link pulley_a bob string
link pulley_a pulley_b
link pulley_b weight string
link beam_left beam_right
observable swing_radius radius
observable angle theta
