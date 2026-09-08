#!/dis/sh
# predatorprey - a Lotka-Volterra lab written entirely in sh(1).
#
# Tk owns the window's structure - the sliders, the buttons, the layout
# and the hit testing - plot(2) owns the pixels of the graph, dynsys(2)
# owns the equations and the integrator, and this file is the model and
# the wiring between them.  It does no floating-point arithmetic at all:
# sh(1) has none, so every number that changes is computed on the Limbo
# side and handed back as text.
#
# The same program as a Limbo command is appl/danby/ecology.b, which
# calls ecolab(2).  This one is here to show that none of the pieces
# need a Limbo program around them.

load std
load expr
load dynsys
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 640x360 'Predator / prey'}
m := ${dynsys new}

fn t {
	or {plot $p tk $*} {
		echo 'predatorprey: tk:' $"status
		exit
	}
}

# --- the model: dynsys(2)'s own language, one line at a time ---------

dynsys $m param birth 0.9 0.02 2.0
dynsys $m param predation 0.9 0.02 2.0
dynsys $m param death 0.6 0.02 2.0
dynsys $m maxtime 200.0
dynsys $m state prey 1.0
dynsys $m state predators 0.5
dynsys $m derivative prey birth prey - predation prey predators
dynsys $m derivative predators predation prey predators - death predators
e := ${dynsys $m check}
if {! ~ $"e ''} {
	echo predatorprey: $"e
	exit
}

# --- the graph: plot(2)'s own language, likewise ---------------------

plot $p table history time prey predators -capacity 20000
plot $p table current prey predators -capacity 1
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

# --- the controls: Tk's own language, in the plot's own window -------

# "plot new" already packed its own frame to fill the window, and pack
# gives the cavity out in the order it was asked, so the plot would take
# all of it and leave the controls nowhere to be - and a click meant for
# a slider would land on the panel underneath it.  Unpack it, build the
# controls, and pack it again last.
t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.reset -text Reset -command {send ev reset}'
t 'button .but.quit -text Quit -command {send ev quit}'
# a fixed width: this label's text changes every frame, and a label whose
# requested size changes makes the whole window renegotiate its geometry
t 'label .but.at -text {} -anchor w -width 300'
t 'pack .but.reset .but.quit -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'
row := 0
for i in ${dynsys $m paramnames} {
	t 'label .par.l'^$i' -text '^$i
	t 'scale .par.'^$i' -from 0.02 -to 2.0 -resolution 0.01 -bigincrement 0.1 -orient horizontal -length 170 -showvalue 1 -command {send ev param}'
	t '.par.'^$i' set '^${dynsys $m getparam $i}
	t 'grid .par.l'^$i' -row '^$row' -column 0 -sticky w -padx 4'
	t 'grid .par.'^$i' -row '^$row' -column 1 -sticky w'
	row = ${expr $row 1 +}
}
t 'pack .f -side top -fill both -expand 1'
t 'bind .f.p <Button-1> {send ev click %x %y}'
t update
plot $p namechan ev
plot $p fit

# --- the loop --------------------------------------------------------
#
# One loop, not two: sh(1) variables are not shared across a fork, so a
# background animator would be stepping its own private copy of the
# state.  "plot recv" with a timeout is what makes one loop enough - an
# empty result means the clock ran out and nothing happened.

state := ${dynsys $m initialstate}
now := 0.0

fn restart {
	now = 0.0
	state = $*
	plot $p history clear
	plot $p history append $now $state
}

fn step {
	i := 0
	while {ntest ${expr $i 20 -}} {
		s := ${dynsys $m step $now 0.01 $state}
		now = ${hd $s}
		state = ${tl $s}
		plot $p history append $now $state
		i = ${expr $i 1 +}
	}
}

fn redraw {
	plot $p clear
	plot $p content margin 45 22 18 30
	plot $p split content x phase 1 series 1 gutter 54
	plot $p view phase phase
	plot $p scale phase x 0 3
	plot $p scale phase y 0 3 reverse
	plot $p axis phase x prey
	plot $p axis phase y predators
	plot $p current clear
	plot $p current append $state
	plot $p line phase history x prey y predators colour foreground width 2
	plot $p point phase current x prey y predators colour live radius 4
	plot $p view series series
	plot $p scale series x 0 $now
	plot $p scale series y 0 3 reverse
	plot $p axis series x time
	plot $p axis series y population
	plot $p line series history x time y prey colour live width 2
	plot $p line series history x time y predators colour accent width 2
	plot $p draw
	t '.but.at configure -text {t '^$now^'}'
}

restart $state
redraw
while {} {
	raw := ${plot $p recv ev 20}
	# "no" is sh-std's own "this list is empty", not a negation - the
	# negation is "!"
	if {no $raw} {
		step
		redraw
	} {
		ev := ${split $raw}
		what := ${hd $ev}
		if {~ $what quit exit} {
			exit
		}
		if {~ $what reset} {
			restart ${dynsys $m initialstate}
		}
		if {~ $what param} {
			for i in ${dynsys $m paramnames} {
				dynsys $m setparam $i ${plot $p tk '.par.'^$i' get'}
			}
			restart ${dynsys $m initialstate}
		}
		if {~ $what click} {
			xy := ${tl $ev}
			st := ${plot $p invert phase ${hd $xy} ${hd ${tl $xy}}}
			if {! no $st} {
				restart $st
			}
		}
		# anything else is the window manager talking
		if {! ~ $what quit exit reset param click} {
			plot $p winctl ${join ' ' $ev}
		}
	}
}
