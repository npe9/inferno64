#!/dis/danby/model.dis
#
# danby/heliumburning - helium burning in a hot star
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Helium burning in a hot star
param triple_alpha 0.04 0.0 0.2
param carbon_capture 0.012 0.0 0.1
param oxygen_capture 0.004 0.0 0.05
param cooling 0.003 0.0 0.03
param temperature 1.0 0.0 3.0
param density 0.2 0.0 2.0
maxtime 100.0
state helium 1.0
state carbon 0.0
state oxygen 0.0
state energy 0.0
eq triplealpha triple_alpha temperature density helium helium helium
eq carboncapture carbon_capture temperature helium carbon
eq oxygencapture oxygen_capture temperature helium oxygen
derivative helium - 3.0 triplealpha - carboncapture - oxygencapture
derivative carbon triplealpha - carboncapture
derivative oxygen carboncapture - oxygencapture
derivative energy 7.0 triplealpha + 4.0 carboncapture + 2.0 oxygencapture - cooling energy
