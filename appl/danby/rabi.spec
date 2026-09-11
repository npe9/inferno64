#!/dis/danby/model.dis
#
# danby/rabi - a two-level atom driven by a resonant field
#
# The other canonical quantum system, and the one danby/schrodinger is
# not: no wave in space, just two levels and the amplitude in each.  A
# qubit is this.  So is a spin in a magnetic field, and so is an atom
# driven by a laser - the equations do not know which, which is the
# whole point of writing them in the Bloch form.
#
# The state is the Bloch vector R = (u, v, w).  w is the population
# INVERSION, the excited fraction less the ground fraction, so w = -1 is
# all atoms in the ground state and w = +1 all excited; u and v are the
# coherence, the part with no classical meaning at all.  The equation of
# motion is a rotation and nothing else,
#
#	dR/dt = W x R,   W = (rabi, 0, detuning)
#
# which is why the length of R never changes: a rotation cannot change
# it.  That is this model's exact invariant and danbylabtest checks it.
#
# On resonance (detuning 0) the vector turns in a circle at the Rabi
# frequency and the atom cycles ground - excited - ground for ever: the
# excited fraction is sin^2(rabi t / 2), which reaches 1.  Off resonance
# the rotation axis tilts out of the plane, the vector sweeps a cone
# that no longer reaches the pole, and the atom can NEVER be fully
# excited however long the field is left on - the most it reaches is
# rabi^2 / (rabi^2 + detuning^2).  Winding the detuning up and watching
# the top of the excited curve come down is the experiment.
#
# Slider ranges are chosen so the slider can land on the values that
# matter: danbylab gives 200 positions across a range and libtk snaps to
# a whole multiple of the resulting resolution, counted from zero.  rabi
# 0..4 steps by 0.02 and detuning -4..4 by 0.04, so 1.0 and 0.0 are both
# exactly reachable, as is a detuning equal to the Rabi frequency - the
# point where the atom can only ever get half way up.
#
family mechanism
title A two-level atom driven by a field
param rabi 1.0 0.0 4.0
param detuning 0.0 -4.0 4.0
param start_inversion -1.0 -1.0 1.0
maxtime 20.0
caption dR/dt = W x R, with R = (u,v,w) and W = (rabi, 0, detuning)
caption sliders: rabi = the drive, detuning = how far off resonance
caption w is the inversion; excited fraction is (1 + w) / 2
caption left: the Bloch vector, drawn in the v-w plane it turns in
caption on resonance it reaches the top. detuned, it never can.
state u 0.0
state v 0.0
state w start_inversion
derivative u 0.0 - detuning v
derivative v detuning u - rabi w
derivative w rabi v
point origin 0.0 , 0.0
point c0 1.000000 , 0.000000
point c1 0.965926 , 0.258819
point c2 0.866025 , 0.500000
point c3 0.707107 , 0.707107
point c4 0.500000 , 0.866025
point c5 0.258819 , 0.965926
point c6 0.000000 , 1.000000
point c7 - 0.258819 , 0.965926
point c8 - 0.500000 , 0.866025
point c9 - 0.707107 , 0.707107
point c10 - 0.866025 , 0.500000
point c11 - 0.965926 , 0.258819
point c12 - 1.000000 , 0.000000
point c13 - 0.965926 , - 0.258819
point c14 - 0.866025 , - 0.500000
point c15 - 0.707107 , - 0.707107
point c16 - 0.500000 , - 0.866025
point c17 - 0.258819 , - 0.965926
point c18 - 0.000000 , - 1.000000
point c19 0.258819 , - 0.965926
point c20 0.500000 , - 0.866025
point c21 0.707107 , - 0.707107
point c22 0.866025 , - 0.500000
point c23 0.965926 , - 0.258819
point tip v , w
link c0 c1 line
link c1 c2 line
link c2 c3 line
link c3 c4 line
link c4 c5 line
link c5 c6 line
link c6 c7 line
link c7 c8 line
link c8 c9 line
link c9 c10 line
link c10 c11 line
link c11 c12 line
link c12 c13 line
link c13 c14 line
link c14 c15 line
link c15 c16 line
link c16 c17 line
link c17 c18 line
link c18 c19 line
link c19 c20 line
link c20 c21 line
link c21 c22 line
link c22 c23 line
link c23 c0 line
link origin tip accent
plain origin c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18 c19 c20 c21 c22 c23
observable excited { 1.0 + w } over 2.0
observable coherence v
shade excited
