#!/dis/danby/model.dis
#
# danby/tunnel - getting through a wall you have not the energy to climb
#
# A particle meets a rectangular barrier of height V and width a.
# Classically the answer is the whole of the story: if E is less than V
# it bounces, every time, and if E is more it goes over, every time.
# Quantum mechanically neither is true.  Below the barrier some of it
# gets through - that is tunnelling, and it is how alpha decay works and
# how a scanning tunnelling microscope sees atoms.  Above the barrier
# some of it bounces back, which is the more surprising half and has no
# classical counterpart at all.
#
# Matching the wave and its slope at both faces gives, with
# k = sqrt(2|E-V|) and the barrier width a,
#
#	T = 4E|E-V| / ( 4E|E-V| + V^2 s ),  R = V^2 s / ( 4E|E-V| + V^2 s )
#
# where s is sinh^2(ka) below the barrier and sin^2(ka) above it.  The
# two are the same formula: sinh is what sin becomes when its argument
# turns imaginary, which is what happens to k when E drops below V.
#
# T and R are written out separately rather than one as 1 minus the
# other, so that T + R = 1 is a real identity about two expressions and
# not a tautology about one.  The test holds it to machine precision at
# every energy, which is conservation of the particle: it must end up
# somewhere.
#
# The resonances are the thing to look for.  Above the barrier, whenever
# ka is a whole number of pi the sine vanishes and T is exactly 1 - the
# barrier becomes perfectly transparent, because the reflections from
# its two faces cancel.  Those energies are E = V + n^2 pi^2 / 2a^2.
# This is the Ramsauer-Townsend effect, which was measured in noble
# gases twenty years before anyone could explain it: slow electrons pass
# through argon as though it were not there.
#
# Widening the barrier kills tunnelling exponentially - T goes as
# exp(-2ka) once ka is large - while moving the resonances closer
# together, since they go as 1/a^2.  Both are visible on one slider.
#
family mechanism
title Tunnelling through a rectangular barrier
param barrier 10.0 0.0 20.0
param width 1.0 0.0 4.0
maxtime 40.0
caption T = 4E|E-V| / (4E|E-V| + V^2 s), R = the same with V^2 s on top
caption s is sinh^2(ka) below the barrier and sin^2(ka) above it
caption sliders: V = barrier height, a = width. x axis is ENERGY.
caption below V it should bounce and does not: that is tunnelling.
caption above V it should pass and does not, except at ka = n pi where
caption the two faces' reflections cancel and T is exactly 1.
eq e t + 0.001
eq d e - barrier
eq ad abs { d } + 0.000001
eq below step { 0.0 - d }
eq kk sqrt { 2.0 ad }
eq arg kk width
eq sh sinh { arg }
eq sn sin { arg }
eq s2 { below sh sh } + { { 1.0 - below } sn sn }
eq num 4.0 e ad
eq bar barrier barrier s2
eq tot num + bar
eq tt num over tot
eq rr bar over tot
state carried 0.0
derivative carried tt
point ground_left - 3.0 , 0.0
point ground_right 6.0 , 0.0
point frame_top - 3.0 , 21.0
point wall_foot 0.0 , 0.0
point wall_top 0.0 , barrier
point far_top width , barrier
point far_foot width , 0.0
point level_left - 3.0 , e
point level_right 6.0 , e
point shot - 2.0 , e
link ground_left ground_right line
link wall_foot wall_top line
link wall_top far_top line
link far_top far_foot line
link level_left level_right accent
plain ground_left ground_right frame_top wall_foot wall_top far_top far_foot level_left level_right
observable transmission tt
observable reflection rr
shade transmission
