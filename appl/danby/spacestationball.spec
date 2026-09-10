#!/dis/danby/model.dis
#
# danby/spacestationball - playing ball in a space station
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Playing ball in a space station
param station_radius 8.0 2.0 20.0
param rotation 0.35 -1.0 1.0
param throw_speed 2.0 0.0 8.0
param throw_angle 0.4 -3.14 3.14
param drag 0.02 0.0 0.2
param ball_mass 1.0 0.1 5.0
maxtime 20.0
state x 0.0
state y 0.7 station_radius
state vx throw_speed cos { throw_angle }
state vy throw_speed sin { throw_angle }
# in the rotating frame the ball feels Coriolis and centrifugal terms
derivative x vx
derivative y vy
derivative vx 2.0 rotation vy + rotation rotation x - { drag vx } over ball_mass
derivative vy - 2.0 rotation vx + rotation rotation y - { drag vy } over ball_mass
point hull_w { - station_radius } , 0.0
point hull_sw { - 0.7 station_radius } , { - 0.7 station_radius }
point hull_s 0.0 , { - station_radius }
point hull_se { 0.7 station_radius } , { - 0.7 station_radius }
point hull_e station_radius , 0.0
point hull_ne { 0.7 station_radius } , { 0.7 station_radius }
point hull_n 0.0 , station_radius
point hull_nw { - 0.7 station_radius } , { 0.7 station_radius }
point ball x , y
link hull_w hull_sw
link hull_sw hull_s
link hull_s hull_se
link hull_se hull_e
link hull_e hull_ne
link hull_ne hull_n
link hull_n hull_nw
link hull_nw hull_w
observable radius sqrt { x x + y y }
observable speed sqrt { vx vx + vy vy }
