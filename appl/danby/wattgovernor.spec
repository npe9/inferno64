#!/dis/danby/model.dis
#
# danby/wattgovernor - Watt's governor
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.
#
family mechanism
title Watt's governor
param arm_length 1.0 0.2 4.0
param gravity 9.81 0.1 20.0
param angle_damping 0.35 0.0 2.0
param drive_torque 2.5 0.0 10.0
param load_gain 0.8 0.0 5.0
param speed_damping 0.18 0.0 2.0
maxtime 35.0
state angle 0.25
state anglerate 0.0
state spin 0.8
eq s sin { angle }
eq c cos { angle }
eq x arm_length s
eq y - arm_length c
derivative angle anglerate
derivative anglerate spin spin s c - { gravity s } over arm_length - angle_damping anglerate
derivative spin drive_torque - load_gain { 1.0 - c } - speed_damping spin
point pivot 0.0 , 0.0
point ball_right x , y
point ball_left { - x } , y
point shaft_bottom 0.0 , { - 1.5 arm_length }
point shaft_top 0.0 , { 0.5 arm_length }
link pivot ball_right
link pivot ball_left
link shaft_bottom shaft_top
observable arm_angle angle
observable shaft_speed spin
