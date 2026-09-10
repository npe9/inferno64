#!/dis/danby/model.dis
#
# danby/maypredator - May's predator-prey model
#
# The whole model is the script below: its parameters and their ranges,
# the two populations and the equations that move them, and the fixed
# point the phase plot marks.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family ecology
title May's predator-prey model
param prey_growth 1.0 0.0 3.0
param prey_capacity 2.0 0.0 4.0
param attack 1.2 0.0 4.0
param half_saturation 0.3 0.0 2.0
param predator_growth 0.8 0.0 3.0
param prey_support 0.7 0.0 2.0
maxtime 100.0
state prey 0.55
state predators 0.22
# The predators' capacity is proportional to the prey, so with no prey
# there is nothing to be logistic about and they simply die off - which
# is what the original's early return says, and what holding the divisor
# at one when the prey is gone says here.
eq alive 1.0 - step { 0.000000000001 - prey }
eq support prey_support prey + 1.0 - alive
eq consumption attack prey predators over { prey + half_saturation }
derivative prey prey_growth prey { 1.0 - prey over prey_capacity } - consumption
derivative predators alive predator_growth predators { 1.0 - predators over support } - { 1.0 - alive } predator_growth predators
# the coexistence prey level is the positive root of a quadratic
equilibrium { prey_growth prey_capacity - prey_growth half_saturation - attack prey_support prey_capacity + sqrt { { prey_growth prey_capacity - prey_growth half_saturation - attack prey_support prey_capacity } { prey_growth prey_capacity - prey_growth half_saturation - attack prey_support prey_capacity } + 4.0 prey_growth prey_growth half_saturation prey_capacity } } over { 2.0 prey_growth } , prey_support { prey_growth prey_capacity - prey_growth half_saturation - attack prey_support prey_capacity + sqrt { { prey_growth prey_capacity - prey_growth half_saturation - attack prey_support prey_capacity } { prey_growth prey_capacity - prey_growth half_saturation - attack prey_support prey_capacity } + 4.0 prey_growth prey_growth half_saturation prey_capacity } } over { 2.0 prey_growth }
