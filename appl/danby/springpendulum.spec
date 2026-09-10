#!/dis/danby/model.dis
#
# danby/springpendulum - a spring pendulum
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A spring pendulum
param mass 1.0 0.1 8.0
param rest_length 1.2 0.2 4.0
param spring 12.0 0.1 50.0
param gravity 9.81 0.1 20.0
param damping 0.08 0.0 2.0
param initial_angle 0.45 -2.5 2.5
maxtime 35.0
state radius rest_length
state radialspeed 0.0
state theta initial_angle
state omega 0.0
eq r { radius + 0.08 + abs { radius - 0.08 } } over 2.0
derivative radius radialspeed
derivative radialspeed r omega omega + gravity cos { theta } - { spring { r - rest_length } } over mass - damping radialspeed
derivative theta omega
derivative omega { - { gravity sin { theta } + 2.0 radialspeed omega } } over r - damping omega
point pivot 0.0 , 0.0
point bob { radius sin { theta } } , { - radius cos { theta } }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link pivot bob spring
link rail_left rail_right
observable length radius
observable angle theta
