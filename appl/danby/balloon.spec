#!/dis/danby/model.dis
#
# danby/balloon - the motion of a balloon and its payload
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The motion of a balloon and its payload
param buoyancy 620.0 0.0 1500.0
param drag 12.0 0.0 60.0
param balloon_mass 55.0 10.0 150.0
param tether 4.0 1.0 10.0
param payload_mass 18.0 1.0 80.0
param gravity 9.81 0.0 20.0
maxtime 30.0
state altitude 2.0
state rise 0.0
state swing 0.25
state swingrate 0.0
eq totalmass balloon_mass + payload_mass
eq riseaccel { buoyancy - totalmass gravity - drag rise } over totalmass
eq x tether sin { swing }
eq y altitude - tether cos { swing }
derivative altitude rise
derivative rise riseaccel
derivative swing swingrate
derivative swingrate { - gravity over tether } sin { swing } - 0.18 swingrate - { riseaccel sin { swing } } over tether
point hook 0.0 , altitude
point payload x , y
point envelope_left - 0.7 , altitude
point envelope_right 0.7 , altitude
point envelope_top 0.0 , { altitude + 1.0 }
link hook payload
link envelope_left envelope_top
link envelope_top envelope_right
link envelope_right envelope_left
observable altitude altitude
observable payload_swing swing
