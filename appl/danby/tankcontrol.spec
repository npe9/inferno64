#!/dis/danby/model.dis
#
# danby/tankcontrol - temperature and volume control in a tank
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Temperature and volume control in a tank
param level_target 1.0 0.0 3.0
param temperature_target 1.0 0.0 3.0
param inflow 0.7 0.0 3.0
param feed_temperature 0.8 0.0 3.0
param level_gain 2.0 0.0 8.0
param temperature_gain 1.5 0.0 8.0
param heat_loss 0.35 0.0 4.0
maxtime 100.0
state liquid_level 0.65
state temperature 0.4
state outlet_valve 0.7
state heater 0.3
# an empty tank has no head to divide by, and neither actuator can be
# driven backwards, so all three are held at their own floor
eq raw_level liquid_level - 0.001
eq level 0.001 + { raw_level + abs { raw_level } } over 2.0
eq rawvalve inflow + level_gain { level - level_target }
eq valvetarget { rawvalve + abs { rawvalve } } over 2.0
eq rawheater temperature_gain { temperature_target - temperature }
eq heatertarget { rawheater + abs { rawheater } } over 2.0
eq outflow outlet_valve sqrt { level }
derivative liquid_level inflow - outflow
derivative temperature { inflow { feed_temperature - temperature } + heater } over level - heat_loss { temperature - 0.25 }
derivative outlet_valve 2.0 { valvetarget - outlet_valve }
derivative heater 2.0 { heatertarget - heater }
