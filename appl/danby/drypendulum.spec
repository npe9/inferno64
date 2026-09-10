#!/dis/danby/model.dis
#
# danby/drypendulum - the pendulum with dry friction
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The pendulum with dry friction
param length 1.0 0.1 4.0
param initial_angle 1.2 -3.0 3.0
param initial_speed 0.0 -8.0 8.0
param gravity 9.81 0.1 20.0
param dry_friction 0.35 0.0 3.0
param mass 1.0 0.1 5.0
maxtime 25.0
state theta initial_angle
state omega initial_speed
eq s sin { theta }
eq c cos { theta }
# Coulomb friction opposes the motion and is exactly zero at rest, which
# is what sign() is three-way for.
eq friction dry_friction sign { omega }
derivative theta omega
derivative omega { - gravity s } over length - friction
point pivot 0.0 , 0.0
point bob { length s } , { - length c }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link pivot bob
link rail_left rail_right
observable angle theta
observable energy { 0.5 { length sup 2 } { omega sup 2 } } + { gravity length { 1.0 - c } }
