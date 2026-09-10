#!/dis/danby/model.dis
#
# danby/flight - the dynamics of flight
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The dynamics of flight
param thrust 1800.0 0.0 5000.0
param lift 0.38 0.0 1.0
param drag 0.025 0.0 0.1
param mass 850.0 300.0 1800.0
param pitch_control 1.8 0.0 5.0
param gravity 9.81 0.0 20.0
maxtime 30.0
state x 0.0
state altitude 100.0
state airspeed 55.0
state pathangle 0.05
state pitch 0.12
state pitchrate 0.0
# the aerodynamics are meaningless below a metre a second, and the path
# angle divides by the speed, so it is held there
eq speed { airspeed + 1.0 + abs { airspeed - 1.0 } } over 2.0
eq alpha pitch - pathangle
eq liftforce lift alpha speed speed
eq dragforce drag speed speed
eq c cos { pitch }
eq s sin { pitch }
derivative x speed cos { pathangle }
derivative altitude speed sin { pathangle }
derivative airspeed { thrust cos { alpha } - dragforce } over mass - gravity sin { pathangle }
derivative pathangle { liftforce + thrust sin { alpha } } over { mass speed } - { gravity cos { pathangle } } over speed
derivative pitch pitchrate
derivative pitchrate pitch_control alpha - 1.2 pitchrate
point tail { - c } , { 1.5 - s }
point nose { 1.2 c } , { 1.5 + 1.2 s }
point wing_root { - 0.1 s } , { 1.5 + 0.1 c }
point wing_tip { 0.65 s } , { 1.5 - 0.65 c }
point ground_left - 1.5 , 0.0
point ground_right 1.5 , 0.0
link tail nose
link wing_root wing_tip
link ground_left ground_right
observable altitude altitude
observable speed airspeed
