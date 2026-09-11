#!/dis/danby/model.dis
#
# danby/bands - why a solid has energies an electron cannot have
#
# One atom gives sharp levels; danby/hydrogen draws them.  A LINE of
# atoms, repeated for ever, gives something else: broad bands of allowed
# energy separated by gaps that no electron in the crystal can occupy at
# all.  That is the whole of why there are conductors, insulators and
# semiconductors, and this is the simplest model that produces it.
#
# The lattice is a Dirac comb - a delta-function barrier of strength P
# every a - which is the Kronig-Penney model.  Bloch's theorem says a
# solution in a periodic potential must repeat up to a phase, psi(x+a) =
# exp(iKa) psi(x), and matching the pieces across one barrier gives
#
#	cos(Ka) = cos(ka) + P sin(ka)/(ka),    k = sqrt(2E)
#
# The left-hand side is a cosine, so it CANNOT leave -1..1.  The
# right-hand side is a function of the energy alone and happily does.
# So an energy is allowed only where the right-hand side happens to land
# inside -1..1, and forbidden everywhere else.  Nothing is approximated
# and nothing is numerical: the gaps are there because a cosine is
# bounded and the function it is being set equal to is not.
#
# The independent variable here is ENERGY, not time.  The model has no
# dynamics at all - it sweeps E from 0 upward and evaluates a formula -
# and the state it is obliged to carry is used for something real: it
# integrates the indicator, so it accumulates the total width of allowed
# band passed so far.
#
# What to watch.  The gaps lose against the bands as the energy rises,
# because the P sin(ka)/(ka) term that pushes the function out of range
# carries a 1/ka and dies away: a fast electron barely notices the
# lattice.  Measured at P=3, a=1, the gaps do NOT shrink in absolute
# width - they are 4.52 then 5.35 wide - but the bands they separate
# widen much faster, 2.98 then 10.28 then 19.32, so the first gap is one
# and a half times the band below it and the next only half.  It is the
# ratio that collapses, and it is the ratio that decides whether a
# material conducts.
#
# Raising strength widens the gaps; a stronger lattice binds harder.
# Widening lattice moves every band down, since the edges sit at
# ka = n pi and a bigger a needs a smaller k - as E = n^2 pi^2 / 2a^2,
# so doubling the spacing quarters every edge.
#
# At exactly ka = n pi the sine term vanishes and the function is
# (-1)^n, so it touches +-1 precisely there: those points are band edges
# for any strength whatever, which is a fact the test pins down.
#
family mechanism
title Energy bands in a periodic lattice
param strength 3.0 0.0 10.0
param lattice 1.0 0.5 2.5
maxtime 50.0
caption cos(Ka) = cos(ka) + P sin(ka)/(ka), with k = sqrt(2E)
caption sliders: P = strength of each barrier, a = lattice spacing
caption the x axis is ENERGY, not time. nothing here moves in time.
caption a cosine cannot leave -1..1, so where the right-hand side does,
caption no electron can exist: those are the gaps. shaded = allowed.
caption left: the lattice itself. gaps lose to the bands as E rises.
eq e t + 0.001
eq kk sqrt { 2.0 e }
eq ka kk lattice
# The lattice itself does not move, and the thing that does is the
# electron: its de Broglie wavelength, 2 pi / k, shrinks as the sweep
# climbs.  Drawn against the spacing it is the whole argument for why
# the gaps close - a fast electron whose wavelength is short compared
# with a barely notices there is a lattice there at all.  Clipped to
# the frame, since at the bottom of the sweep it is 140 wide.
eq lamraw 6.283185307179586 over kk
eq lam lamraw - { lamraw - 12.5 } step { lamraw - 12.5 }
eq raw { cos { ka } } + { strength { sin { ka } } over ka }
eq fhi 3.0
eq flo 0.0 - 3.0
eq f raw - { raw - fhi } step { raw - fhi } + { flo - raw } step { flo - raw }
eq allowedq step { 1.0 - abs { raw } }
state bandwidth 0.0
derivative bandwidth allowedq
point frame_right 12.5000 , 0.0
point wave_base 0.0 , - 1.6
point wave_tip lam , - 1.6
point frame_bottom 0.0 , - 2.4
point frame_top 0.0 , 10.0
point base_left 0.0 , 0.0
point foot0 0 lattice , 0.0
point peak0 0 lattice , strength
point foot1 1 lattice , 0.0
point peak1 1 lattice , strength
point foot2 2 lattice , 0.0
point peak2 2 lattice , strength
point foot3 3 lattice , 0.0
point peak3 3 lattice , strength
point foot4 4 lattice , 0.0
point peak4 4 lattice , strength
point foot5 5 lattice , 0.0
point peak5 5 lattice , strength
link base_left frame_right line
link wave_base wave_tip accent
link foot0 peak0 accent
link foot1 peak1 accent
link foot2 peak2 accent
link foot3 peak3 accent
link foot4 peak4 accent
link foot5 peak5 accent
plain wave_base frame_bottom frame_right frame_top base_left foot0 peak0 foot1 peak1 foot2 peak2 foot3 peak3 foot4 peak4 foot5 peak5
observable band_function f
observable allowed allowedq
shade allowed
