#!/dis/danby/model.dis
#
# danby/packet - a free particle, spreading
#
# Every other quantum model here draws a standing shape: schrodinger,
# hydrogen and bands all solve for states that do not change, and
# tunnel is a steady beam.  This one is the exception and the reason it
# is worth having - it is the only one in which a wave function
# actually MOVES and CHANGES, and the diagram draws it doing so.
#
# A free Gaussian packet, released at the origin with momentum k.  Its
# centre travels at the group velocity k/m, which is the classical
# answer and the only classical thing about it.  Its width does not
# stay put:
#
#	sigma(t) = sqrt( sigma0^2 + ( t / 2 m sigma0 )^2 )
#
# so it spreads, and it spreads FASTER the more tightly it was
# localised to begin with - the sigma0 in the denominator.  Pin a
# particle down and it escapes you sooner.  That is the uncertainty
# principle as a statement about time rather than about measurement.
#
# A free particle's momentum spread never changes, since nothing acts
# on it: dp = 1/(2 sigma0) for ever.  So the product is
#
#	dx dp = sigma(t) / 2 sigma0
#
# which is exactly 1/2 at release - the minimum a Gaussian can have,
# which is why this packet and no other is the one textbooks start
# from - and grows from there and never returns.  The test pins that
# 1/2 exactly.
#
# The diagram is the point of the model.  It samples |psi|^2 at
# forty-eight fixed positions and draws the curve through them, so the
# bump visibly slides right and flattens as the run goes on.  Because
# the sample positions are fixed and the frame is pinned, the motion on
# screen is the packet moving and not the view rescaling around it.
#
family mechanism
title A free particle, spreading
param momentum 1.0 0.0 4.0
param initial_width 1.0 0.25 2.25
param mass 1.0 0.5 2.5
maxtime 15.0
caption sigma(t) = sqrt( sigma0^2 + (t / 2 m sigma0)^2 )
caption sliders: k = momentum, sigma0 = initial_width, m = mass
caption the centre moves at k/m. the width only ever grows.
caption a tighter packet spreads FASTER - sigma0 is in the denominator.
caption dx dp starts at exactly 1/2, the least a packet can have.
caption left: |psi|^2 itself, moving and flattening. it is normalised,
caption so as it widens it must also fall.
eq sigma sqrt { { initial_width initial_width } + { { t over { 2.0 mass initial_width } } sup 2 } }
eq peak 1.0 over { sigma 2.5066282746310002 }
state centre 0.0
derivative centre momentum over mass
eq g0 peak exp { 0.0 - { { - 4.000000 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g1 peak exp { 0.0 - { { - 3.489362 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g2 peak exp { 0.0 - { { - 2.978723 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g3 peak exp { 0.0 - { { - 2.468085 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g4 peak exp { 0.0 - { { - 1.957447 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g5 peak exp { 0.0 - { { - 1.446809 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g6 peak exp { 0.0 - { { - 0.936170 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g7 peak exp { 0.0 - { { - 0.425532 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g8 peak exp { 0.0 - { { 0.085106 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g9 peak exp { 0.0 - { { 0.595745 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g10 peak exp { 0.0 - { { 1.106383 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g11 peak exp { 0.0 - { { 1.617021 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g12 peak exp { 0.0 - { { 2.127660 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g13 peak exp { 0.0 - { { 2.638298 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g14 peak exp { 0.0 - { { 3.148936 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g15 peak exp { 0.0 - { { 3.659574 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g16 peak exp { 0.0 - { { 4.170213 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g17 peak exp { 0.0 - { { 4.680851 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g18 peak exp { 0.0 - { { 5.191489 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g19 peak exp { 0.0 - { { 5.702128 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g20 peak exp { 0.0 - { { 6.212766 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g21 peak exp { 0.0 - { { 6.723404 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g22 peak exp { 0.0 - { { 7.234043 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g23 peak exp { 0.0 - { { 7.744681 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g24 peak exp { 0.0 - { { 8.255319 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g25 peak exp { 0.0 - { { 8.765957 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g26 peak exp { 0.0 - { { 9.276596 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g27 peak exp { 0.0 - { { 9.787234 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g28 peak exp { 0.0 - { { 10.297872 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g29 peak exp { 0.0 - { { 10.808511 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g30 peak exp { 0.0 - { { 11.319149 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g31 peak exp { 0.0 - { { 11.829787 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g32 peak exp { 0.0 - { { 12.340426 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g33 peak exp { 0.0 - { { 12.851064 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g34 peak exp { 0.0 - { { 13.361702 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g35 peak exp { 0.0 - { { 13.872340 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g36 peak exp { 0.0 - { { 14.382979 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g37 peak exp { 0.0 - { { 14.893617 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g38 peak exp { 0.0 - { { 15.404255 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g39 peak exp { 0.0 - { { 15.914894 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g40 peak exp { 0.0 - { { 16.425532 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g41 peak exp { 0.0 - { { 16.936170 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g42 peak exp { 0.0 - { { 17.446809 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g43 peak exp { 0.0 - { { 17.957447 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g44 peak exp { 0.0 - { { 18.468085 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g45 peak exp { 0.0 - { { 18.978723 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g46 peak exp { 0.0 - { { 19.489362 - centre } sup 2 } over { 2.0 sigma sigma } }
eq g47 peak exp { 0.0 - { { 20.000000 - centre } sup 2 } over { 2.0 sigma sigma } }
point base_left - 4.000000 , 0.0
point base_right 20.000000 , 0.0
point frame_top - 4.000000 , 0.45
point d0 - 4.000000 , g0
point d1 - 3.489362 , g1
point d2 - 2.978723 , g2
point d3 - 2.468085 , g3
point d4 - 1.957447 , g4
point d5 - 1.446809 , g5
point d6 - 0.936170 , g6
point d7 - 0.425532 , g7
point d8 0.085106 , g8
point d9 0.595745 , g9
point d10 1.106383 , g10
point d11 1.617021 , g11
point d12 2.127660 , g12
point d13 2.638298 , g13
point d14 3.148936 , g14
point d15 3.659574 , g15
point d16 4.170213 , g16
point d17 4.680851 , g17
point d18 5.191489 , g18
point d19 5.702128 , g19
point d20 6.212766 , g20
point d21 6.723404 , g21
point d22 7.234043 , g22
point d23 7.744681 , g23
point d24 8.255319 , g24
point d25 8.765957 , g25
point d26 9.276596 , g26
point d27 9.787234 , g27
point d28 10.297872 , g28
point d29 10.808511 , g29
point d30 11.319149 , g30
point d31 11.829787 , g31
point d32 12.340426 , g32
point d33 12.851064 , g33
point d34 13.361702 , g34
point d35 13.872340 , g35
point d36 14.382979 , g36
point d37 14.893617 , g37
point d38 15.404255 , g38
point d39 15.914894 , g39
point d40 16.425532 , g40
point d41 16.936170 , g41
point d42 17.446809 , g42
point d43 17.957447 , g43
point d44 18.468085 , g44
point d45 18.978723 , g45
point d46 19.489362 , g46
point d47 20.000000 , g47
link base_left base_right line
link d0 d1 line
link d1 d2 line
link d2 d3 line
link d3 d4 line
link d4 d5 line
link d5 d6 line
link d6 d7 line
link d7 d8 line
link d8 d9 line
link d9 d10 line
link d10 d11 line
link d11 d12 line
link d12 d13 line
link d13 d14 line
link d14 d15 line
link d15 d16 line
link d16 d17 line
link d17 d18 line
link d18 d19 line
link d19 d20 line
link d20 d21 line
link d21 d22 line
link d22 d23 line
link d23 d24 line
link d24 d25 line
link d25 d26 line
link d26 d27 line
link d27 d28 line
link d28 d29 line
link d29 d30 line
link d30 d31 line
link d31 d32 line
link d32 d33 line
link d33 d34 line
link d34 d35 line
link d35 d36 line
link d36 d37 line
link d37 d38 line
link d38 d39 line
link d39 d40 line
link d40 d41 line
link d41 d42 line
link d42 d43 line
link d43 d44 line
link d44 d45 line
link d45 d46 line
link d46 d47 line
plain base_left base_right frame_top d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d12 d13 d14 d15 d16 d17 d18 d19 d20 d21 d22 d23 d24 d25 d26 d27 d28 d29 d30 d31 d32 d33 d34 d35 d36 d37 d38 d39 d40 d41 d42 d43 d44 d45 d46 d47
observable width sigma
observable uncertainty sigma over { 2.0 initial_width }
