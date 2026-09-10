#!/dis/danby/model.dis
#
# danby/foodchain - plants, herbivores and carnivores
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Plants, herbivores, and carnivores
param plant_growth 1.5 0.0 3.0
param capacity 1.8 0.0 3.0
param grazing 1.4 0.0 3.0
param plant_conversion 0.85 0.0 2.0
param herbivore_death 0.45 0.0 2.0
param predation 1.0 0.0 3.0
param prey_conversion 0.75 0.0 2.0
param carnivore_death 0.35 0.0 2.0
maxtime 100.0
state plants 0.9
state herbivores 0.22
state carnivores 0.08
eq grazed grazing plants herbivores
eq predated predation herbivores carnivores
derivative plants plant_growth plants { 1.0 - plants over capacity } - grazed
derivative herbivores plant_conversion grazed - herbivore_death herbivores - predated
derivative carnivores prey_conversion predated - carnivore_death carnivores
