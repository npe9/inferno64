#!/dis/danby/model.dis
#
# danby/twoslit - the experiment that has all of it in it
#
# Feynman called the double slit the one phenomenon that contains the
# only mystery, and this draws what it produces: fringes, under an
# envelope, with the two coming from different things.
#
# Send particles at a screen through two slits of width w a distance d
# apart, and count where they land.  A single particle arrives at one
# spot; send enough and the pattern that builds up is
#
#	I = [ sin(beta)/beta ]^2  cos^2(alpha)
#	alpha = pi d sin(theta) / lambda
#	beta  = pi w sin(theta) / lambda
#
# The cos^2 is INTERFERENCE, from the two paths differing by d sin
# theta, and it is the part with no classical account: each particle
# goes through both slits, in the only sense in which that sentence
# means anything.  The sinc^2 is DIFFRACTION, from the width of one
# slit, and it is the envelope the fringes sit under.  Close the second
# slit - separation to zero - and the fringes vanish and only the
# envelope remains.  That is the model's own control and the test makes
# it.
#
# The angles are exact, sin(theta) = y / sqrt(L^2 + y^2), and not the
# paraxial y/L.  So the fringes are exactly where d sin(theta) = n
# lambda and the envelope vanishes exactly where w sin(theta) = n
# lambda; the familiar spacing lambda L / d is what those become near
# the axis, and is visibly wrong at the edges of a short screen.
#
# The missing orders are worth hunting.  When d is a whole multiple of
# w, a fringe maximum lands exactly on an envelope zero and simply is
# not there - the interference says put light here, the diffraction says
# there is none to put.  Set separation to 2 and slit_width to 1 and
# count the gaps.
#
# sin(beta)/beta is 0/0 on the axis, where the central maximum is, and
# the value there is 1 rather than anything ambiguous.  It is written as
# sin(bb)/bb with bb = |beta| + 1e-12: sine is even so this is the same
# function everywhere beta is not zero, and at zero it is sin(1e-12)/1e-12,
# which is 1 to every bit a double has.  Guarding only the DENOMINATOR -
# sin(beta)/(|beta|+eps) - is the obvious thing and leaves the hole
# exactly where it matters, returning 0 at the brightest point on the
# screen.  It did, until a test asked for the central maximum.
#
family mechanism
title Two slits, and the pattern they make
param wavelength 0.5 0.0 2.0
param separation 4.0 0.0 8.0
param slit_width 1.0 0.0 2.0
param distance 20.0 5.0 45.0
maxtime 20.0
caption I = [sin(b)/b]^2 cos^2(a), a = pi d sin(th)/L, b = pi w sin(th)/L
caption sliders: lambda, d = separation, w = slit_width, L = distance
caption cos^2 is INTERFERENCE, from two paths. it needs both slits.
caption sinc^2 is DIFFRACTION, from one slit's width. it is the envelope.
caption set separation to 0 and the fringes go; the envelope stays.
caption when d is a multiple of w, whole fringes are missing.
eq y t - 10.0
eq sint y over sqrt { { distance distance } + { y y } }
eq alpha 3.14159265358979312 separation sint over wavelength
eq beta 3.14159265358979312 slit_width sint over wavelength
eq bb { abs { beta } } + 0.000000000001
eq env { { sin { bb } } { sin { bb } } } over { bb bb }
eq fringe { cos { alpha } } { cos { alpha } }
state counted 0.0
derivative counted env fringe
point frame_far 45.0 , 0.0
point frame_top 0.0 , 10.0
point frame_bot 0.0 , - 10.0
point bar_a_lo 0.0 , - 10.0
point bar_a_hi 0.0 , 0.0 - { { separation + slit_width } over 2.0 }
point bar_b_lo 0.0 , 0.0 - { { separation - slit_width } over 2.0 }
point bar_b_hi 0.0 , { separation - slit_width } over 2.0
point bar_c_lo 0.0 , { separation + slit_width } over 2.0
point bar_c_hi 0.0 , 10.0
point screen_lo distance , - 10.0
point screen_hi distance , 10.0
point spot distance , y
link bar_a_lo bar_a_hi accent
link bar_b_lo bar_b_hi accent
link bar_c_lo bar_c_hi accent
link screen_lo screen_hi line
plain frame_far frame_top frame_bot bar_a_lo bar_a_hi bar_b_lo bar_b_hi bar_c_lo bar_c_hi screen_lo screen_hi
observable intensity env fringe
observable envelope env
shade intensity
