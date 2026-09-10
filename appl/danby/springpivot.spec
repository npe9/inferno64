#!/dis/danby/model.dis
#
# danby/springpivot - a pendulum on a spring pivot
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A pendulum with a spring pivot
param pivot_mass 1.0 0.1 8.0
param bob_mass 1.0 0.1 8.0
param length 1.4 0.2 4.0
param spring 8.0 0.1 30.0
param gravity 9.81 0.1 20.0
param damping 0.08 0.0 2.0
param initial_angle 0.5 -2.5 2.5
maxtime 30.0
state x 0.0
state vx 0.0
state theta initial_angle
state omega 0.0
eq s sin { theta }
eq c cos { theta }
eq pivotaccel { - spring x - damping vx + bob_mass length omega omega s + bob_mass gravity s c } over { pivot_mass + bob_mass s s }
derivative x vx
derivative vx pivotaccel
derivative theta omega
derivative omega { - pivotaccel c - gravity s } over length - damping omega
point pivot x , 0.0
point bob { x + length s } , { - length c }
point rail_left - 2.0 , 0.0
point rail_right x , 0.0
link pivot bob spring
link rail_left rail_right
observable pivot_position x
observable angle theta
