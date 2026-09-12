#!/dis/sh
# fitlab - fit a polynomial to data, in sh(1), and see what r-squared
# does and does not tell you.
#
# The data is Anscombe's second set, which is the whole argument for
# looking at data rather than only at its summaries: it is an almost
# perfect downward parabola, and a STRAIGHT LINE through it has
# r-squared 0.666 - the same as the genuinely linear first set of the
# quartet.  The summary cannot tell them apart.  The picture can, at a
# glance, and that is the point.
#
# Drag the degree slider.  At 1 the line is plainly wrong and the number
# says 0.67; at 2 the curve goes through the points and the number says
# 1.00.  Keep going and watch r-squared creep up towards 1 while the
# curve starts to wander between the points: with eleven points and a
# degree-10 polynomial it will pass through every one of them exactly,
# and mean nothing at all.
#
# Tk owns the sliders, plot(2) the pixels, stats(2) the fitting.

load std
load expr
load hoc
load stats
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 660x420 'Fitting'}
d := ${stats new}
stats $d columns 2
stats $d data 10 9.14 8 8.14 13 8.74 9 8.77 11 9.26 14 8.10
stats $d data 6 6.13 4 3.10 12 9.13 7 7.26 5 4.74

fn t {
	or {plot $p tk $*} {
		echo 'fitlab: tk:' $"status
		exit
	}
}

plot $p table points x y -capacity 64
plot $p table curve x y -capacity 512
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

# the data never changes, so it goes in once
plot $p points append ${stats $d table}

t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.quit -text Quit -command {send ev quit}'
t 'label .but.at -text {} -anchor w -width 400'
t 'pack .but.quit -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'
t 'label .par.ld -text {degree}'
t 'scale .par.deg -from 1 -to 9 -resolution 1 -orient horizontal -length 260 -showvalue 1 -command {send ev param}'
t '.par.deg set 1'
t 'grid .par.ld -row 0 -column 0 -sticky w -padx 4'
t 'grid .par.deg -row 0 -column 1 -sticky w'
t 'pack .f -side top -fill both -expand 1'
t update
plot $p namechan ev
plot $p fit

fn rebuild {
	deg := ${plot $p tk '.par.deg get'}
	stats $d polyfit 0 1 $deg
	r2 := ${stats $d rsquared 0 1}

	# the fitted curve, sampled finely enough to show it wandering
	plot $p curve clear
	i := 0
	while {ntest ${expr $i 201 -}} {
		xx := ${hoc '3.0 + 12.0*'^$i^'/200.0'}
		plot $p curve append $xx ${stats $d predict $xx}
		i = ${expr $i 1 +}
	}

	plot $p clear
	plot $p content margin 50 22 18 30
	plot $p view v content
	plot $p scale v x 3 15
	plot $p scale v y 2 11 reverse
	plot $p axis v x x
	plot $p axis v y y
	plot $p line v curve x x y y colour live width 2
	plot $p point v points x x y y colour accent radius 4
	plot $p draw
	t '.but.at configure -text {degree '^$deg^'   r-squared '^$r2^'}'
}

rebuild
while {} {
	raw := ${plot $p recv ev 200}
	if {! no $raw} {
		ev := ${split $raw}
		what := ${hd $ev}
		if {~ $what quit exit} {
			exit
		}
		if {~ $what param} {
			rebuild
		}
		if {! ~ $what quit exit param} {
			plot $p winctl ${join ' ' $ev}
		}
	}
}
