#!/dis/sh
# trusslab - load a truss and watch it deflect, in sh(1).
#
# A Warren truss, eight metres across and three deep, pinned at one end
# and on a roller at the other, with a load hung from whichever joint
# the slider picks.  Drawn twice: where it is, in grey, and where it
# went, coloured by what each member is doing - green for tension, red
# for compression.
#
# THE SCALE SLIDER IS THE POINT.  At a scale of 1 the two drawings lie
# on top of each other and nothing appears to happen, because the whole
# structure moves about three millimetres under a tonne.  That is what a
# stiff structure IS, and it is why every textbook drawing of a
# deflected shape is exaggerated without saying so.  Wind the scale up
# and the shape appears.
#
# Tk owns the sliders, plot(2) the pixels, frame(2) the structure.

load std
load expr
load frame
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 700x500 'Truss'}
f := ''

fn t {
	or {plot $p tk $*} {
		echo 'trusslab: tk:' $"status
		exit
	}
}

NMEM := 7

plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour tension 16r178f86ff
plot $p colour compress 16rb85c38ff
i := 0
while {ntest ${expr $i $NMEM -}} {
	plot $p table u^$i x y -capacity 4
	plot $p table d^$i x y -capacity 4
	i = ${expr $i 1 +}
}

t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.quit -text Quit -command {send ev quit}'
t 'label .but.at -text {} -anchor w -width 440'
t 'pack .but.quit -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'
t 'label .par.ll -text {load kN}'
t 'scale .par.load -from 1 -to 100 -resolution 1 -orient horizontal -length 220 -showvalue 1 -command {send ev param}'
t '.par.load set 10'
t 'grid .par.ll -row 0 -column 0 -sticky w -padx 4'
t 'grid .par.load -row 0 -column 1 -sticky w'
t 'label .par.ls -text {scale}'
t 'scale .par.scale -from 1 -to 2000 -resolution 1 -orient horizontal -length 220 -showvalue 1 -command {send ev param}'
t '.par.scale set 200'
t 'grid .par.ls -row 1 -column 0 -sticky w -padx 4'
t 'grid .par.scale -row 1 -column 1 -sticky w'
t 'label .par.lw -text {load at}'
t 'frame .par.where'
t 'button .par.where.c -text left -command {send ev where c}'
t 'button .par.where.d -text middle -command {send ev where d}'
t 'button .par.where.e -text right -command {send ev where e}'
t 'pack .par.where.c .par.where.d .par.where.e -side left'
t 'grid .par.lw -row 2 -column 0 -sticky w -padx 4'
t 'grid .par.where -row 2 -column 1 -sticky w'
t 'pack .f -side top -fill both -expand 1'
t update
plot $p namechan ev
plot $p fit

where := d

fn rebuild {
	kn := ${plot $p tk '.par.load get'}
	sc := ${plot $p tk '.par.scale get'}

	if {! ~ $"f ''} {
		frame del $f
	}
	f = ${frame new}
	# a Warren truss: bottom chord a-b-e, top chord c-d, diagonals
	frame $f spec 'node a 0 0'
	frame $f spec 'node b 8 0'
	frame $f spec 'node e 4 0'
	frame $f spec 'node c 2 3'
	frame $f spec 'node d 6 3'
	frame $f spec 'bar a e 200e9 0.01'
	frame $f spec 'bar e b 200e9 0.01'
	frame $f spec 'bar c d 200e9 0.01'
	frame $f spec 'bar a c 200e9 0.01'
	frame $f spec 'bar c e 200e9 0.01'
	frame $f spec 'bar e d 200e9 0.01'
	frame $f spec 'bar d b 200e9 0.01'
	frame $f spec 'pin a'
	frame $f spec 'roller b y'
	frame $f spec 'force '^$where^' 0 -'^$kn^'000'
	frame $f solve

	plot $p clear
	plot $p content margin 45 22 18 30
	plot $p view v content
	plot $p scale v x -1 9
	plot $p scale v y -2 5 reverse
	plot $p axis v x metres
	plot $p axis v y metres

	i := 0
	worst := 0
	while {ntest ${expr $i $NMEM -}} {
		un := u^$i
		dn := d^$i
		plot $p $un clear
		plot $p $un append ${frame $f member $i}
		plot $p $dn clear
		plot $p $dn append ${frame $f member $i deflected $sc}
		plot $p line v $un x x y y colour grid width 1
		# green in tension, red in compression - the sign of the
		# axial force, which is the first thing anyone wants to know
		ax := ${hd ${frame $f force $i}}
		col := tension
		if {~ $ax -*} {
			col = compress
		}
		plot $p line v $dn x x y y colour $col width 3
		i = ${expr $i 1 +}
	}
	plot $p draw

	t '.but.at configure -text {load '^$kn^'kN at '^$where^'   drop '^${frame $f displacement $where y}^' m   scale x'^$sc^'}'
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
		if {~ $what where} {
			where = ${hd ${tl $ev}}
			rebuild
		}
		if {! ~ $what quit exit param where} {
			plot $p winctl ${join ' ' $ev}
		}
	}
}
