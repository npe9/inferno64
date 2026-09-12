#!/dis/sh
# circuitlab - a series RLC lab written entirely in sh(1).
#
# Tk owns the window's structure - the sliders, the buttons, the layout
# - plot(2) owns the pixels of the graph, circuit(2) owns the netlist
# and the transient, hoc(2) does the arithmetic, and this file is the
# wiring between them.  It does no floating-point arithmetic of its own:
# sh(1) has none, so every number that changes is computed on the Limbo
# side and handed back as text.
#
# The netlist is rebuilt from the sliders on every move, which is what
# `circuit new' is cheap enough for, and the slider values go into it as
# TEXT with circuit(2)'s own SI suffixes - "1.4m" is fourteen tenths of
# a millihenry and nothing here had to convert it.
#
# The thing to watch is the damping.  Below zeta = 1 the capacitor
# overshoots the supply and rings; at 1 it arrives as fast as it can
# without overshooting; above it the circuit is sluggish.  Drag R.

load std
load hoc
load circuit
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 680x420 'Series RLC'}
c := ''

fn t {
	or {plot $p tk $*} {
		echo 'circuitlab: tk:' $"status
		exit
	}
}

# --- the graph: plot(2)'s own language -------------------------------

plot $p table wave t v i -capacity 4000
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

# --- the controls: Tk's own language, in the plot's own window -------
#
# "plot new" already packed its own frame to fill the window, and pack
# gives the cavity out in the order it was asked, so the plot would take
# all of it and leave the controls nowhere to be.  Unpack it, build the
# controls, and pack it again last.

t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.quit -text Quit -command {send ev quit}'
t 'label .but.at -text {} -anchor w -width 420'
t 'pack .but.quit -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'

t 'label .par.lr -text {R ohm}'
t 'scale .par.r -from 1 -to 200 -resolution 1 -bigincrement 10 -orient horizontal -length 200 -showvalue 1 -command {send ev param}'
t '.par.r set 20'
t 'grid .par.lr -row 0 -column 0 -sticky w -padx 4'
t 'grid .par.r -row 0 -column 1 -sticky w'

t 'label .par.ll -text {L mH}'
t 'scale .par.l -from 0.2 -to 5.0 -resolution 0.1 -bigincrement 0.5 -orient horizontal -length 200 -showvalue 1 -command {send ev param}'
t '.par.l set 1.0'
t 'grid .par.ll -row 1 -column 0 -sticky w -padx 4'
t 'grid .par.l -row 1 -column 1 -sticky w'

t 'label .par.lc -text {C uF}'
t 'scale .par.c -from 0.2 -to 5.0 -resolution 0.1 -bigincrement 0.5 -orient horizontal -length 200 -showvalue 1 -command {send ev param}'
t '.par.c set 1.0'
t 'grid .par.lc -row 2 -column 0 -sticky w -padx 4'
t 'grid .par.c -row 2 -column 1 -sticky w'

t 'pack .f -side top -fill both -expand 1'
t update
plot $p namechan ev
plot $p fit

# --- the model -------------------------------------------------------
#
# Everything here is one function: read the sliders, work out how long
# to run for and how finely, build the netlist, run it, and draw.  The
# transient is computed all at once rather than animated, so there is
# nothing to step and the loop only has to wait for events.

fn rebuild {
	r := ${plot $p tk '.par.r get'}
	l := ${plot $p tk '.par.l get'}
	cf := ${plot $p tk '.par.c get'}

	# the natural frequency, and from it a window four cycles wide
	w0 := ${hoc '1.0/sqrt(('^$l^'*1e-3)*('^$cf^'*1e-6))'}
	span := ${hoc '8.0*3.14159265358979/'^$w0}
	dt := ${hoc $span^'/400.0'}
	# the damping ratio, which is what the sliders are really moving
	z := ${hoc '('^$r^'/2.0)*sqrt(('^$cf^'*1e-6)/('^$l^'*1e-3))'}
	# a current axis wide enough for the worst case: a step of one volt
	# into a circuit whose characteristic impedance is sqrt(L/C)
	imax := ${hoc '1.3/sqrt(('^$l^'*1e-3)/('^$cf^'*1e-6))'}

	if {! ~ $"c ''} {
		circuit del $c
	}
	c = ${circuit new}
	circuit $c spec 'V1 in 0 1'
	circuit $c spec 'R1 in a '^$r
	circuit $c spec 'L1 a out '^$l^'m'
	circuit $c spec 'C1 out 0 '^$cf^'u'
	circuit $c watch v out
	circuit $c watch i L1
	circuit $c begin
	circuit $c run $dt 400

	plot $p wave clear
	plot $p wave append ${circuit $c trace}

	plot $p clear
	plot $p content margin 62 22 18 30
	plot $p split content y volts 1 amps 1 gutter 34
	plot $p view volts volts
	plot $p scale volts x 0 $span
	plot $p scale volts y 0 2 reverse
	plot $p axis volts x time
	plot $p axis volts y 'volts on C'
	plot $p line volts wave x t y v colour live width 2
	plot $p view amps amps
	plot $p scale amps x 0 $span
	plot $p scale amps y ${hoc '0.0-'^$imax} $imax reverse
	plot $p axis amps x time
	plot $p axis amps y 'amps in L'
	plot $p line amps wave x t y i colour accent width 2
	plot $p draw

	t '.but.at configure -text {zeta '^$z^'}'
}

# --- the loop --------------------------------------------------------

rebuild
while {} {
	raw := ${plot $p recv ev 200}
	# "no" is sh-std's own "this list is empty", not a negation
	if {! no $raw} {
		ev := ${split $raw}
		what := ${hd $ev}
		if {~ $what quit exit} {
			exit
		}
		if {~ $what param} {
			rebuild
		}
		# anything else is the window manager talking
		if {! ~ $what quit exit param} {
			plot $p winctl ${join ' ' $ev}
		}
	}
}
