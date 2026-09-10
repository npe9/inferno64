#!/dis/danby/model.dis
#
# danby/pegpendulum - a pendulum wrapped around a peg
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title A pendulum wrapped around a peg
param string 2.0 0.5 5.0
param initial_angle 0.75 -2.5 2.5
param gravity 9.81 0.1 20.0
param damping 0.04 0.0 1.0
param peg_depth 0.8 0.1 4.5
maxtime 30.0
state theta initial_angle
state omega 0.0
# The string catches on the peg only on the swing that is going the
# other way, and only if the peg is above the bob's own reach.
eq fits step { string - 0.05 - peg_depth }
eq wrapped fits step { - theta }
eq effective string - wrapped peg_depth
# The drawing clamps the peg to the string, which the equations do not.
eq shown_depth { peg_depth + string - 0.05 - abs { peg_depth - string + 0.05 } } over 2.0
eq drawn_length string - wrapped shown_depth
derivative theta omega
derivative omega { - gravity sin { theta } } over effective - damping omega
point anchor 0.0 , 0.0
point peg 0.0 , { - shown_depth }
point bob { drawn_length sin { theta } } , { - wrapped shown_depth - drawn_length cos { theta } }
point rail_left - 0.7 , 0.0
point rail_right 0.7 , 0.0
link anchor peg
link peg bob
link rail_left rail_right
observable angle theta
observable effective_length effective
