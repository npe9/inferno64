#!/dis/danby/model.dis
#
# danby/lowbombing - low-level bombing
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Low-level bombing
param aircraft_speed 3.0 0.2 10.0
param release_height 1.4 0.2 5.0
param gravity 9.81 0.1 20.0
param drag 0.08 0.0 2.0
param release_delay 0.0 0.0 3.0
maxtime 8.0
state aircraft_x - 3.0
state aircraft_y release_height
state bomb_x - 3.0
state bomb_y release_height
state bomb_vx aircraft_speed
state bomb_vy 0.0
state clock 0.0
# Before release the bomb is still on the aircraft; after it, it
# falls.  "clock >= delay" is 1 - step(delay - clock): step is zero
# AT zero, so the complement is the >= the original tests, exactly.
eq released 1.0 - step { release_delay - clock }
eq carried 1.0 - released
eq speed sqrt { bomb_vx bomb_vx + bomb_vy bomb_vy }
derivative aircraft_x aircraft_speed
derivative aircraft_y 0.0
derivative bomb_x carried aircraft_speed + released bomb_vx
derivative bomb_y released bomb_vy
derivative bomb_vx released { - drag speed bomb_vx }
derivative bomb_vy released { - gravity - drag speed bomb_vy }
derivative clock 1.0
point aircraft aircraft_x , aircraft_y
point bomb bomb_x , bomb_y
point ground_left - 4.0 , 0.0
point ground_right 6.0 , 0.0
point target_base 2.0 , 0.0
point target_top 2.0 , 0.35
link ground_left ground_right
link target_base target_top
observable bomb_range bomb_x
observable bomb_height bomb_y
