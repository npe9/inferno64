#!/dis/danby/model.dis
#
# danby/running - running
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Running
param drive 320.0 20.0 700.0
param drag 0.9 0.05 3.0
param mass 70.0 35.0 120.0
param fatigue 0.7 0.0 2.0
param stride 2.2 0.8 4.0
param recovery 0.18 0.0 0.8
maxtime 20.0
state speed 1.0
state tiredness 0.0
state phase 0.0
state distance 0.0
# A tired runner cannot push backwards, so the drive is held at zero.
# ("rear", not "back": back is an eqn motion keyword.)
eq raw drive { 1.0 - fatigue tiredness }
eq effective { raw + abs { raw } } over 2.0
eq hipy 1.05 + 0.05 sin { 2.0 phase }
eq shouldery hipy + 0.55
eq front 0.55 sin { phase }
eq rear 0.55 sin { phase + PI }
derivative speed { effective - drag speed speed } over mass
derivative tiredness 0.002 speed speed - recovery tiredness
derivative phase { 2.0 PI speed } over stride
derivative distance speed
point hip 0.0 , hipy
point shoulder 0.08 , shouldery
point head 0.08 , { shouldery + 0.25 }
point knee_front { 0.55 front } , { hipy - 0.45 }
point foot_front front , 0.0
point knee_back { 0.55 rear } , { hipy - 0.45 }
point foot_back rear , 0.0
point hand_back { 0.45 sin { phase + PI } } , { shouldery - 0.25 }
point hand_front { 0.45 sin { phase } } , { shouldery - 0.25 }
link hip shoulder
link shoulder head
link hip knee_front
link knee_front foot_front
link hip knee_back
link knee_back foot_back
link shoulder hand_back
link shoulder hand_front
observable speed speed
observable distance distance
