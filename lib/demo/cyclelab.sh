#!/dis/sh
# cyclelab - a P-v diagram of an air-standard cycle, in sh(1).
#
# Pick a cycle, move the compression or pressure ratio, and watch the
# loop change shape.  The number under the graph is the efficiency, and
# the closed form it should equal is beside it.
#
# THE AREA INSIDE THE LOOP IS THE WORK.  That is the whole reason to
# draw one of these rather than print the efficiency, and it is why the
# curve is drawn along the real process between corners instead of
# straight across: an isentrope bows well below its chord - at a
# compression ratio of 9 the middle of the compression stroke sits at
# 279 kPa where the straight line says 1.29 MPa - so a diagram with
# straight sides shows an area, and therefore a work, that is not the
# engine's.
#
# Watch the Otto loop get taller and thinner as the ratio rises: that is
# the efficiency going up, and it is also why a real engine cannot go on
# doing it, since the top corner is a temperature the fuel would reach
# before the piston does.

load std
load expr
load thermo
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 680x480 'Air-standard cycle'}
t := ${thermo new}
thermo $t gas air

fn tk {
	or {plot $p tk $*} {
		echo 'cyclelab: tk:' $"status
		exit
	}
}

plot $p table loop v pr -capacity 1000
plot $p table corners v pr -capacity 8
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

tk 'pack forget .f'
tk 'frame .par'
tk 'frame .but'
tk 'button .but.quit -text Quit -command {send ev quit}'
tk 'label .but.at -text {} -anchor w -width 430'
tk 'pack .but.quit -side left'
tk 'pack .but.at -side left -padx 10'
tk 'pack .but -side bottom -fill x'
tk 'pack .par -side bottom -fill x'
tk 'label .par.lr -text {ratio}'
tk 'scale .par.ratio -from 2 -to 20 -resolution 1 -orient horizontal -length 240 -showvalue 1 -command {send ev param}'
tk '.par.ratio set 9'
tk 'grid .par.lr -row 0 -column 0 -sticky w -padx 4'
tk 'grid .par.ratio -row 0 -column 1 -sticky w'
tk 'label .par.lc -text {cycle}'
tk 'frame .par.which'
tk 'button .par.which.o -text Otto -command {send ev cycle otto}'
tk 'button .par.which.d -text Diesel -command {send ev cycle diesel}'
tk 'button .par.which.b -text Brayton -command {send ev cycle brayton}'
tk 'pack .par.which.o .par.which.d .par.which.b -side left'
tk 'grid .par.lc -row 1 -column 0 -sticky w -padx 4'
tk 'grid .par.which -row 1 -column 1 -sticky w'
tk 'pack .f -side top -fill both -expand 1'
tk update
plot $p namechan ev
plot $p fit

kind := otto

fn rebuild {
	r := ${plot $p tk '.par.ratio get'}

	if {~ $kind otto} {
		thermo $t otto $r 300 100000 1000000
	} {
		if {~ $kind diesel} {
			# the cutoff must stay below the compression ratio
			thermo $t diesel $r 2 300 100000
		} {
			thermo $t brayton $r 300 100000 1400
		}
	}

	plot $p loop clear
	plot $p loop append ${thermo $t path 30}
	plot $p corners clear
	plot $p corners append ${thermo $t path 1}

	plot $p clear
	plot $p content margin 62 22 18 30
	plot $p view v content
	plot $p scale v x 0 1.0
	plot $p scale v y 0 8e6 reverse
	plot $p axis v x 'volume m3/kg'
	plot $p axis v y 'pressure Pa'
	plot $p line v loop x v y pr colour live width 2
	plot $p point v corners x v y pr colour accent radius 4
	plot $p draw

	tk '.but.at configure -text {'^$kind^' ratio '^$r^'   efficiency '^${thermo $t efficiency}^'}'
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
		if {~ $what cycle} {
			kind = ${hd ${tl $ev}}
			rebuild
		}
		if {! ~ $what quit exit param cycle} {
			plot $p winctl ${join ' ' $ev}
		}
	}
}
