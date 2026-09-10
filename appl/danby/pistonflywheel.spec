#!/dis/danby/model.dis
#
# danby/pistonflywheel - the motion of a piston and flywheel
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The motion of a piston and flywheel
param crank_radius 0.65 0.1 2.0
param rod_length 1.5 0.3 5.0
param wheel_inertia 2.0 0.1 10.0
param drive_torque 1.0 -5.0 8.0
param damping 0.18 0.0 3.0
param load 0.8 0.0 5.0
maxtime 30.0
state angle 0.0
state spin 0.6
eq cx crank_radius cos { angle }
eq cy crank_radius sin { angle }
# the rod cannot reach past the crank, so the root is held at zero rather
# than going imaginary when the two are badly matched
eq raw rod_length rod_length - cy cy
eq inside { raw + abs { raw } } over 2.0
eq piston cx + sqrt { inside }
derivative angle spin
derivative spin { drive_torque - damping spin - load sin { angle } } over wheel_inertia
point hub 0.0 , 0.0
point crank_pin cx , cy
point piston_pin piston , 0.0
point piston_bottom piston , - 0.35
point piston_top piston , 0.35
point guide_left { - crank_radius } , 0.0
point guide_right crank_radius , 0.0
link hub crank_pin
link crank_pin piston_pin
link piston_bottom piston_top
link guide_left guide_right
observable piston_position piston
observable wheel_speed spin
