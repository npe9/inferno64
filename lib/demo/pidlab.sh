#!/dis/sh
# pidlab - tune a PID controller by hand, in sh(1).
#
# The plant is 1/((s+1)(s+2)), the sliders are the three gains, and what
# is drawn is the closed loop's step response.  Tk owns the sliders,
# plot(2) the pixels, control(2) the transfer functions and the
# integration, and this file is the wiring.  It does no floating-point
# arithmetic of its own: sh(1) has none.
#
# What the loop is made of, in the order it is built:
#
#	C = kp + ki/s + kd s/(taud s + 1)	the controller
#	L = C P					the open loop
#	T = L/(1 + L)				the closed loop
#
# The readout is the open loop's margins and the closed loop's step
# metrics.  Watch the phase margin fall as kd is taken away and the
# overshoot rise to meet it: they are two views of the same thing, which
# is the entire point of the exercise.
#
# `settled' comes first in the metrics and is 0 when the run was too
# short for the response to finish - in which case every number after it
# is measured from the wrong place.  Wind ki down far enough and it will
# happen.

load std
load control
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 700x460 'PID'}

# the plant, which never changes
plant := ${control new}
control $plant num 1
control $plant den 1 3 2
# unity feedback
one := ${control new}
control $one num 1
control $one den 1
# rebuilt every time a slider moves
ctrl := ${control new}
open := ${control new}
closed := ${control new}

fn t {
	or {plot $p tk $*} {
		echo 'pidlab: tk:' $"status
		exit
	}
}

plot $p table resp t y -capacity 4000
plot $p table target t y -capacity 2
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

# --- the controls ----------------------------------------------------

t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.quit -text Quit -command {send ev quit}'
t 'label .but.at -text {} -anchor w -width 460'
t 'pack .but.quit -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'

t 'label .par.lp -text {Kp}'
t 'scale .par.kp -from 0.0 -to 20.0 -resolution 0.1 -bigincrement 1.0 -orient horizontal -length 220 -showvalue 1 -command {send ev param}'
t '.par.kp set 2.0'
t 'grid .par.lp -row 0 -column 0 -sticky w -padx 4'
t 'grid .par.kp -row 0 -column 1 -sticky w'

t 'label .par.li -text {Ki}'
t 'scale .par.ki -from 0.0 -to 20.0 -resolution 0.1 -bigincrement 1.0 -orient horizontal -length 220 -showvalue 1 -command {send ev param}'
t '.par.ki set 3.0'
t 'grid .par.li -row 1 -column 0 -sticky w -padx 4'
t 'grid .par.ki -row 1 -column 1 -sticky w'

t 'label .par.ld -text {Kd}'
t 'scale .par.kd -from 0.0 -to 5.0 -resolution 0.05 -bigincrement 0.5 -orient horizontal -length 220 -showvalue 1 -command {send ev param}'
t '.par.kd set 0.5'
t 'grid .par.ld -row 2 -column 0 -sticky w -padx 4'
t 'grid .par.kd -row 2 -column 1 -sticky w'

t 'pack .f -side top -fill both -expand 1'
t update
plot $p namechan ev
plot $p fit

# --- the model -------------------------------------------------------

span := 20.0
nsteps := 2000
dt := 0.01

fn rebuild {
	kp := ${plot $p tk '.par.kp get'}
	ki := ${plot $p tk '.par.ki get'}
	kd := ${plot $p tk '.par.kd get'}

	# a bare kd*s cannot be built; the filter is what makes it proper
	control $ctrl pid $kp $ki $kd 0.01
	control $open num ${control $ctrl num}
	control $open den ${control $ctrl den}
	control $open series $plant
	control $closed num ${control $open num}
	control $closed den ${control $open den}
	control $closed feedback $one -1

	st := ${control $closed stable}
	if {~ $st 0} {
		# an unstable loop has no step response worth drawing, and
		# integrating one produces numbers that leave the axes
		plot $p resp clear
		plot $p clear
		plot $p content margin 55 22 18 30
		plot $p view v content
		plot $p scale v x 0 $span
		plot $p scale v y 0 2 reverse
		plot $p axis v x time
		plot $p axis v y output
		plot $p draw
		t '.but.at configure -text {closed loop UNSTABLE - '^${control $closed text}^'}'
	} {
		control $closed step $dt $nsteps
		plot $p resp clear
		plot $p resp append ${control $closed trace}
		plot $p target clear
		plot $p target append 0.0 1.0
		plot $p target append $span 1.0

		plot $p clear
		plot $p content margin 55 22 18 30
		plot $p view v content
		plot $p scale v x 0 $span
		plot $p scale v y 0 2 reverse
		plot $p axis v x time
		plot $p axis v y output
		plot $p line v target x t y y colour grid width 1
		plot $p line v resp x t y y colour live width 2
		plot $p draw

		m := ${control $closed metrics}
		gm := ${control $open margins}
		t '.but.at configure -text {settled '^${hd $m}^'  overshoot '^${hd ${tl ${tl ${tl ${tl ${tl $m}}}}}}^'  phase margin '^${hd ${tl ${tl $gm}}}^'}'
	}
}

# --- the loop --------------------------------------------------------

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
