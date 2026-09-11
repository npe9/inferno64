#!/dis/danby/model.dis
#
# danby/hydrogen - the radial wave function of a hydrogen-like atom
#
# danby/schrodinger shoots a particle in a made-up well.  This shoots
# the real one: an electron in the Coulomb field of a nucleus, the only
# atom with an exact answer and the reason anyone believed the theory.
#
# In atomic units the radial function u(r) = r R(r) obeys
#
#	u'' = [ l(l+1)/r^2 - 2Z/r - 2E ] u
#
# and the bound states sit at E = -Z^2 / 2n^2 exactly, with n running
# l+1, l+2, ...  For Z = 1 that is -0.5, then -0.125, then -0.0556 -
# which is to say the Lyman and Balmer lines, the colours of hydrogen.
#
# Raising angular_momentum is the point of the model.  l(l+1)/r^2 is the
# centrifugal barrier, and going inwards it climbs faster than the
# Coulomb attraction falls, so an electron with angular momentum is
# held off the nucleus: a wall grows on the left of the diagram and the
# density stops reaching r = 0.  It is why the ground state must have
# l = 0, and why the lowest level for a given l is n = l+1.
#
# Three numbers here were measured rather than chosen, because shooting
# outward into a classically forbidden region is unstable and hydrogen
# is far worse for it than a harmonic well: the 1s state decays like
# e^-r over the whole range, so the growing solution is amplified by
# e^40 against it.
#
# The march starts at start_radius, not at 0, because 1/r and 1/r^2 are
# singular there - and it starts from the SERIES, u = r^(l+1)(1 - Zr/(l+1)),
# not from the leading term alone.  That one extra term is worth a
# factor of a hundred: the error it leaves is O(r0^2) rather than O(r0),
# and since that error is what seeds the growing solution, the 1s tail
# at the wall fell from 1500 - four thousand times the size of the peak
# it is supposed to sit under - to something that reads as zero.
#
# start_radius is 0.001 and not smaller.  Contamination keeps falling
# as r0^2 all the way down, but the equation stiffens as 1/r: below
# about 0.001 the library's own step of 0.005 can no longer resolve the
# inner region and the error comes back.  At 0.0001 the 1s tail is
# 0.44, worse than at 0.001, and larger than the peak.  That optimum
# does not exist at a finer step, which is exactly why it had to be
# measured at the step the model actually runs at.
#
# The wall is at 20.  Nearer and the excited states cannot be told
# apart - one slider notch off 2s changes the tail by 8x at r = 16 and
# by 176x at r = 20.  Further and the ground state's picture is ruined -
# its tail is 2.6 per cent of its own peak at r = 20 and 17 per cent at
# r = 22.  Twenty is where all three levels are both clean and sharp.
#
# Energy -0.5..0 steps by 0.0025, so -0.5 (n=1) and -0.125 (n=2) are
# exactly reachable; -0.0556 (n=3) is not a multiple of that and can
# only be approached.  angular_momentum steps by 0.02, so every integer
# is reachable.  A non-integer l is left alone rather than rounded: it
# solves the equation perfectly well and is simply not a state of
# anything, and eqn cannot round in any case - `int' there is the
# integral SIGN and eqn2hoc(2) refuses to translate it rather than guess.
#
family mechanism
title The radial wave function of a hydrogen-like atom
param energy -0.5 -0.5 0.0
param charge 1.0 0.5 2.5
param angular_momentum 0.0 0.0 4.0
param start_radius 0.001 0.001 0.021
maxtime 20.0
caption u'' = [ l(l+1)/r^2 - 2Z/r - 2E ] u, for u(r) = r R(r)
caption sliders: E = energy, Z = charge, l = angular_momentum
caption levels are E = -Z^2/2n^2: for Z=1, -0.5 then -0.125 then -0.0556
caption left: the effective potential, with E drawn across it
caption right: u, and u^2 which is the radial density - the shaded
caption area under it is a probability. raise l and the centrifugal
caption barrier walls the electron away from the nucleus.
eq ell angular_momentum
eq lsq ell { ell + 1.0 }
eq r t + start_radius
eq vhi 0.2
eq vlo 0.0 - 0.6
eq curvature { lsq over { r r } } - { 2.0 charge over r } - 2.0 energy
eq p1 { lsq over 0.00500000 } - { charge over 0.050000 }
eq q1 p1 - { p1 - vhi } step { p1 - vhi } + { vlo - p1 } step { vlo - p1 }
eq p2 { lsq over 0.08000000 } - { charge over 0.200000 }
eq q2 p2 - { p2 - vhi } step { p2 - vhi } + { vlo - p2 } step { vlo - p2 }
eq p3 { lsq over 0.40500000 } - { charge over 0.450000 }
eq q3 p3 - { p3 - vhi } step { p3 - vhi } + { vlo - p3 } step { vlo - p3 }
eq p4 { lsq over 1.28000000 } - { charge over 0.800000 }
eq q4 p4 - { p4 - vhi } step { p4 - vhi } + { vlo - p4 } step { vlo - p4 }
eq p5 { lsq over 3.12500000 } - { charge over 1.250000 }
eq q5 p5 - { p5 - vhi } step { p5 - vhi } + { vlo - p5 } step { vlo - p5 }
eq p6 { lsq over 6.48000000 } - { charge over 1.800000 }
eq q6 p6 - { p6 - vhi } step { p6 - vhi } + { vlo - p6 } step { vlo - p6 }
eq p7 { lsq over 12.00500000 } - { charge over 2.450000 }
eq q7 p7 - { p7 - vhi } step { p7 - vhi } + { vlo - p7 } step { vlo - p7 }
eq p8 { lsq over 20.48000000 } - { charge over 3.200000 }
eq q8 p8 - { p8 - vhi } step { p8 - vhi } + { vlo - p8 } step { vlo - p8 }
eq p9 { lsq over 32.80500000 } - { charge over 4.050000 }
eq q9 p9 - { p9 - vhi } step { p9 - vhi } + { vlo - p9 } step { vlo - p9 }
eq p10 { lsq over 50.00000000 } - { charge over 5.000000 }
eq q10 p10 - { p10 - vhi } step { p10 - vhi } + { vlo - p10 } step { vlo - p10 }
eq p11 { lsq over 73.20500000 } - { charge over 6.050000 }
eq q11 p11 - { p11 - vhi } step { p11 - vhi } + { vlo - p11 } step { vlo - p11 }
eq p12 { lsq over 103.68000000 } - { charge over 7.200000 }
eq q12 p12 - { p12 - vhi } step { p12 - vhi } + { vlo - p12 } step { vlo - p12 }
eq p13 { lsq over 142.80500000 } - { charge over 8.450000 }
eq q13 p13 - { p13 - vhi } step { p13 - vhi } + { vlo - p13 } step { vlo - p13 }
eq p14 { lsq over 192.08000000 } - { charge over 9.800000 }
eq q14 p14 - { p14 - vhi } step { p14 - vhi } + { vlo - p14 } step { vlo - p14 }
eq p15 { lsq over 253.12500000 } - { charge over 11.250000 }
eq q15 p15 - { p15 - vhi } step { p15 - vhi } + { vlo - p15 } step { vlo - p15 }
eq p16 { lsq over 327.68000000 } - { charge over 12.800000 }
eq q16 p16 - { p16 - vhi } step { p16 - vhi } + { vlo - p16 } step { vlo - p16 }
eq p17 { lsq over 417.60500000 } - { charge over 14.450000 }
eq q17 p17 - { p17 - vhi } step { p17 - vhi } + { vlo - p17 } step { vlo - p17 }
eq p18 { lsq over 524.88000000 } - { charge over 16.200000 }
eq q18 p18 - { p18 - vhi } step { p18 - vhi } + { vlo - p18 } step { vlo - p18 }
eq p19 { lsq over 651.60500000 } - { charge over 18.050000 }
eq q19 p19 - { p19 - vhi } step { p19 - vhi } + { vlo - p19 } step { vlo - p19 }
eq p20 { lsq over 800.00000000 } - { charge over 20.000000 }
eq q20 p20 - { p20 - vhi } step { p20 - vhi } + { vlo - p20 } step { vlo - p20 }
state u { start_radius sup { angular_momentum + 1.0 } } { 1.0 - { charge start_radius over { angular_momentum + 1.0 } } }
state slope { { angular_momentum + 1.0 } start_radius sup angular_momentum } - { { charge { angular_momentum + 2.0 } over { angular_momentum + 1.0 } } start_radius sup { angular_momentum + 1.0 } }
derivative u slope
derivative slope curvature u
point origin 0.0 , 0.0
point w1 0.050000 , q1
point w2 0.200000 , q2
point w3 0.450000 , q3
point w4 0.800000 , q4
point w5 1.250000 , q5
point w6 1.800000 , q6
point w7 2.450000 , q7
point w8 3.200000 , q8
point w9 4.050000 , q9
point w10 5.000000 , q10
point w11 6.050000 , q11
point w12 7.200000 , q12
point w13 8.450000 , q13
point w14 9.800000 , q14
point w15 11.250000 , q15
point w16 12.800000 , q16
point w17 14.450000 , q17
point w18 16.200000 , q18
point w19 18.050000 , q19
point w20 20.000000 , q20
point levelleft 0.0 , energy
point levelright 20.0 , energy
point shot r , energy
link w1 w2 line
link w2 w3 line
link w3 w4 line
link w4 w5 line
link w5 w6 line
link w6 w7 line
link w7 w8 line
link w8 w9 line
link w9 w10 line
link w10 w11 line
link w11 w12 line
link w12 w13 line
link w13 w14 line
link w14 w15 line
link w15 w16 line
link w16 w17 line
link w17 w18 line
link w18 w19 line
link w19 w20 line
link levelleft levelright accent
plain origin w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 levelleft levelright
observable amplitude u
observable density u u
shade density
