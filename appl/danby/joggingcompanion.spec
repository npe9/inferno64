#!/dis/danby/model.dis
#
# danby/joggingcompanion - jogging with a companion
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Jogging with a companion
param leader_pace 3.2 0.5 8.0
param response 0.8 0.0 3.0
param spacing 1.5 0.2 5.0
param drag 0.7 0.0 2.0
param coupling 0.45 0.0 2.0
param mass 70.0 35.0 120.0
maxtime 25.0
state leader_x 0.0
state leader_v 2.0
state follower_x - 2.5
state follower_v 1.0
eq separation leader_x - follower_x
eq separationerror separation - spacing
derivative leader_x leader_v
derivative leader_v response { leader_pace - leader_v } - { drag leader_v } over mass
derivative follower_x follower_v
derivative follower_v response { leader_pace - follower_v } + coupling separationerror - { drag follower_v } over mass
point leader_feet 0.0 , 0.0
point leader_hip 0.0 , 1.0
point leader_head 0.0 , 1.4
point leader_hand_left - 0.35 , 0.45
point leader_hand_right 0.35 , 0.45
point follower_feet { - separation } , 0.0
point follower_hip { - separation } , 1.0
point follower_head { - separation } , 1.4
point follower_hand_left { - separation - 0.35 } , 0.45
point follower_hand_right { - separation + 0.35 } , 0.45
link leader_feet leader_hip
link leader_hip leader_head
link leader_hip leader_hand_left
link leader_hip leader_hand_right
link follower_feet follower_hip
link follower_hip follower_head
link follower_hip follower_hand_left
link follower_hip follower_hand_right
observable leader_speed leader_v
observable separation separation
