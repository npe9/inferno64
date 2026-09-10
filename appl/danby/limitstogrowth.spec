#!/dis/danby/model.dis
#
# danby/limitstogrowth - limits to growth
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.
#
family population
title Limits to growth: population, capital, pollution, resources
param population_growth 2.0 0.0 4.0
param base_death_rate 0.5 0.0 2.0
param pollution_mortality 3.0 0.0 6.0
param investment_rate 1.2 0.0 3.0
param capital_depreciation 0.3 0.0 2.0
param pollution_generation 0.8 0.0 2.0
param pollution_decay 0.4 0.0 2.0
param resource_extraction 0.6 0.0 2.0
maxtime 100.0
state population 1.0
state capital 0.5
state pollution 0.1
state resources 1.0
# Both saturate towards 1 as capital or resources grow and towards 0 as
# either runs out - the half-saturation shape used across this family, so
# growth stalls smoothly rather than going singular at zero.
eq capitalfactor capital over { capital + 1.0 }
eq resourcefactor resources over { resources + 0.1 }
eq births population_growth population capitalfactor resourcefactor
eq deaths base_death_rate population { 1.0 + pollution_mortality pollution }
eq investment investment_rate population resourcefactor
eq depreciation capital_depreciation capital
eq extraction resource_extraction capital resourcefactor
derivative population births - deaths
derivative capital investment - depreciation
derivative pollution pollution_generation capital - pollution_decay pollution
derivative resources - extraction
