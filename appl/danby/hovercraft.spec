#!/dis/danby/model.dis
#
# danby/hovercraft - the motion of a hovercraft
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title The motion of a hovercraft
param thrust 900.0 0.0 2500.0
param drag 1.8 0.0 8.0
param mass 500.0 100.0 1200.0
param rudder 0.35 -1.0 1.0
param inertia 650.0 100.0 1500.0
param yaw_damping 1.4 0.0 5.0
maxtime 25.0
state x 0.0
state y 0.0
state vx 0.0
state vy 0.0
state heading 0.0
state yawrate 0.0
eq c cos { heading }
eq s sin { heading }
derivative x vx
derivative y vy
derivative vx { thrust c - drag vx } over mass
derivative vy { thrust s - drag vy } over mass
derivative heading yawrate
derivative yawrate { thrust rudder - yaw_damping yawrate } over inertia
point bow c , s
point port { - 0.7 c - 0.6 s } , { - 0.7 s + 0.6 c }
point starboard { - 0.7 c + 0.6 s } , { - 0.7 s - 0.6 c }
point centre 0.0 , 0.0
link bow port
link port starboard
link starboard bow
link centre bow
observable speed sqrt { vx vx + vy vy }
observable heading heading
