#!/dis/sh
# cavitylab - the lid-driven cavity, in sh(1).
#
# A square box of fluid with the lid sliding along the top.  It is the
# standard benchmark in computational fluid dynamics for a plain reason:
# it has no closed form at all, so nothing can be checked by formula and
# everything must be computed.
#
# The arrows are the velocity field - a vector layer, which is right
# here and would be wrong on a truss, because a velocity really is an
# arrow at a point.  The curve below is the horizontal velocity down the
# centreline, which is the profile the published tables give.
#
# WATCH THE VISCOSITY. At high viscosity the whole box turns over in one
# slow roll and the centreline profile is nearly a straight shear.  Lower
# it and the main vortex tightens toward the lid, the middle of the box
# goes almost still, and corner eddies appear that the coarse grid can
# barely hold - which is where a benchmark stops being a demonstration
# and starts being a test of the method.
#
# It runs a fixed number of steps per redraw rather than animating, so
# each press is a measured amount of simulated time.

load std
load expr
load flow
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 640x600 'Lid-driven cavity'}
f := ''

fn t {
	or {plot $p tk $*} {
		echo 'cavitylab: tk:' $"status
		exit
	}
}

plot $p table arrows x y dx dy -capacity 400
plot $p table centre u y -capacity 64
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.quit -text Quit -command {send ev quit}'
t 'button .but.step -text {run 200 steps} -command {send ev advance}'
t 'button .but.reset -text Reset -command {send ev reset}'
t 'label .but.at -text {} -anchor w -width 330'
t 'pack .but.quit .but.step .but.reset -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'
t 'label .par.lv -text {viscosity}'
t 'scale .par.visc -from 0.01 -to 0.2 -resolution 0.01 -orient horizontal -length 240 -showvalue 1 -command {send ev reset}'
t '.par.visc set 0.05'
t 'grid .par.lv -row 0 -column 0 -sticky w -padx 4'
t 'grid .par.visc -row 0 -column 1 -sticky w'
t 'pack .f -side top -fill both -expand 1'
t update
plot $p namechan ev
plot $p fit

fn restart {
	visc := ${plot $p tk '.par.visc get'}
	if {! ~ $"f ''} {
		flow del $f
	}
	f = ${flow new}
	flow $f grid 24 24 1.0 1.0 $visc cavity
	flow $f init 0 0
	flow $f lid 1.0
}

fn redraw {
	plot $p arrows clear
	plot $p arrows append ${flow $f field 12 12 0.06}
	plot $p centre clear
	plot $p centre append ${flow $f profile 0.5 24}

	plot $p clear
	plot $p content margin 48 20 16 28
	plot $p split content y box 3 prof 2 gutter 30
	plot $p view b box
	plot $p scale b x 0 1
	plot $p scale b y 0 1 reverse
	plot $p axis b x x
	plot $p axis b y y
	plot $p vector b arrows x x y y dx dx dy dy colour live width 1
	plot $p view s prof
	plot $p scale s x -0.5 1.0
	plot $p scale s y 0 1 reverse
	plot $p axis s x 'u on the centreline'
	plot $p axis s y y
	plot $p line s centre x u y y colour accent width 2
	plot $p draw

	t '.but.at configure -text {t '^${flow $f time}^'  div '^${flow $f divergence}^'}'
}

restart
redraw
while {} {
	raw := ${plot $p recv ev 200}
	if {! no $raw} {
		ev := ${split $raw}
		what := ${hd $ev}
		if {~ $what quit exit} {
			exit
		}
		if {~ $what reset} {
			restart
			redraw
		}
		if {~ $what advance} {
			dt := ${flow $f maxstep}
			flow $f run $dt 200
			redraw
		}
		if {! ~ $what quit exit reset advance} {
			plot $p winctl ${join ' ' $ev}
		}
	}
}
