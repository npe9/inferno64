#!/dis/danby/model.dis
#
# danby/violetsantsrodents - violets, ants and rodents
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Violets, ants, and rodents
param violet_growth 0.8 0.0 2.0
param capacity 1.5 0.0 3.0
param ant_benefit 0.35 0.0 1.5
param rodent_grazing 0.5 0.0 2.0
param ant_conversion 0.8 0.0 2.0
param ant_death 0.3 0.0 1.5
param ant_deterrence 1.2 0.0 3.0
param rodent_death 0.35 0.0 1.5
maxtime 100.0
state violets 0.7
state ants 0.3
state rodents 0.18
# the ants carry seeds, which saturates as violets get dense, and they
# put the rodents off, which divides the grazing rather than subtracting
eq seedservice ants violets over { 1.0 + violets }
eq rodentfood violets rodents over { 1.0 + ant_deterrence ants }
derivative violets violet_growth violets { 1.0 - violets over capacity } + ant_benefit seedservice - rodent_grazing rodentfood
derivative ants ant_conversion seedservice - ant_death ants
derivative rodents rodentfood - rodent_death rodents
