#!/dis/danby/model.dis
#
# danby/shipmotion - pitching and rolling at sea
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Pitching and rolling at sea
param wave 0.28 0.0 1.2
param roll_stiffness 2.4 0.1 6.0
param pitch_stiffness 1.5 0.1 6.0
param damping 0.35 0.0 2.0
param roll_frequency 0.8 0.1 3.0
param pitch_frequency 1.15 0.1 3.0
maxtime 30.0
state roll 0.15
state rollrate 0.0
state pitch - 0.08
state pitchrate 0.0
eq cr cos { roll }
eq sr sin { roll }
eq cp cos { pitch }
eq sp sin { pitch }
derivative roll rollrate
derivative rollrate wave sin { roll_frequency t } - roll_stiffness roll - damping rollrate
derivative pitch pitchrate
derivative pitchrate wave sin { pitch_frequency t + 0.7 } - pitch_stiffness pitch - damping pitchrate
point roll_port { - 2.5 - cr } , { 0.8 - sr }
point roll_starboard { - 2.5 + cr } , { 0.8 + sr }
point roll_keel - 2.5 , 0.2
point pitch_bow { - sp } , { 0.8 - cp }
point pitch_stern { 3.0 + sp } , { 0.8 + cp }
point pitch_forefoot 0.0 , 0.2
point pitch_heel 3.0 , 0.2
link roll_port roll_starboard
link roll_port roll_keel
link roll_keel roll_starboard
link pitch_bow pitch_stern
link pitch_bow pitch_forefoot
link pitch_forefoot pitch_heel
link pitch_heel pitch_stern
observable roll roll
observable pitch pitch
