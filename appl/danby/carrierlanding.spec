#!/dis/danby/model.dis
#
# danby/carrierlanding - landing an airplane on an aircraft carrier
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Landing an airplane on an aircraft carrier
param aircraft_mass 8.0 0.5 30.0
param cable_stiffness 12.0 0.1 80.0
param cable_slack 1.2 0.1 4.0
param damping 0.5 0.0 10.0
param deck_heave 0.18 0.0 1.0
param heave_rate 0.7 0.1 4.0
maxtime 18.0
state x - 2.8
state v 3.2
state phase 0.0
eq deck deck_heave sin { phase }
eq cable sqrt { x x + deck deck }
# the arrester cable pulls only once it is stretched past its slack, and
# only along its own line - which is undefined at the origin
eq taut step { cable - cable_slack }
eq tension taut cable_stiffness { cable - cable_slack } { cable - cable_slack }
eq reaches step { cable - 0.000001 }
eq direction reaches x over { cable + 1.0 - reaches }
derivative x v
derivative v { - tension direction - damping v } over aircraft_mass
derivative phase heave_rate
point deck_aft - 3.5 , deck
point deck_bow 3.5 , deck
point aircraft x , { deck + 0.2 }
point wing_port { x - 0.35 } , { deck + 0.2 }
point wing_starboard { x + 0.35 } , { deck + 0.2 }
point cable_anchor 0.0 , deck
link deck_aft deck_bow
link aircraft wing_port
link wing_port wing_starboard
link aircraft cable_anchor
observable aircraft_position x
observable aircraft_speed v
