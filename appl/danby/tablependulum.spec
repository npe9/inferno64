#!/dis/danby/model.dis
#
# danby/tablependulum - a pendulum coupled to a mass on a table
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A pendulum coupled to a mass on a table
param table_mass 2.0 0.1 10.0
param bob_mass 1.0 0.1 10.0
param string_length 1.8 0.4 5.0
param initial_angle 0.5 -2.0 2.0
param gravity 9.81 0.1 20.0
param friction 0.12 0.0 2.0
maxtime 30.0
state radius 0.65 string_length
state radialspeed 0.0
state theta initial_angle
state omega 0.0
# both lengths are held off zero, since either can be pulled through the
# hole; hoc has no max, so it is written out
eq r { radius + 0.08 + abs { radius - 0.08 } } over 2.0
eq hang string_length - r
eq pendulumlength { hang + 0.08 + abs { hang - 0.08 } } over 2.0
eq radialaccel { bob_mass pendulumlength omega omega + bob_mass gravity cos { theta } - friction radialspeed } over { table_mass + bob_mass }
derivative radius radialspeed
derivative radialspeed radialaccel
derivative theta omega
derivative omega { - { gravity sin { theta } - 2.0 radialspeed omega } } over pendulumlength
point pivot 0.0 , 0.0
point bob { pendulumlength sin { theta } } , { - pendulumlength cos { theta } }
point table_mass_point r , 0.0
point hole 0.0 , 0.0
point table_left - 2.0 , 0.0
point table_right 2.0 , 0.0
link pivot bob
link table_mass_point hole
link table_left table_right
observable table_radius radius
observable pendulum_angle theta
