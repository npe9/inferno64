#!/dis/sh
# spectrumlab - two tones under noise, and a filter that takes one away.
#
# The signal is a strong tone at 1/16 of the sampling rate, a weaker one
# at 5/16, and noise on top.  The sliders move the filter's cutoff and
# choose the window.  Three things are drawn: the waveform, its
# spectrum, and the filter's own response over the top of the spectrum,
# so that what the filter is about to do and what it did are in the same
# picture.
#
# WHAT THE WINDOW IS FOR.  Switch it to `rect' and watch the noise floor
# rise - not because the signal changed, but because a rectangular
# window smears every tone across the whole spectrum.  The weak tone
# disappears into the smear of the strong one.  That is the entire
# argument for windowing, and it is invisible in any single number.
#
# Tk owns the sliders, plot(2) the pixels, signal(2) the transform and
# the filter.

load std
load expr
load signal
load plot
pctl newpgrp
ifs = ' '

p := ${plot new 720x480 'Spectrum'}
raw := ${signal new}
work := ${signal new}

fn t {
	or {plot $p tk $*} {
		echo 'spectrumlab: tk:' $"status
		exit
	}
}

N := 512

plot $p table wave n v -capacity 1200
plot $p table spec f power -capacity 400
plot $p table resp f mag -capacity 400
plot $p colour foreground 16r20272cff
plot $p colour grid 16rd6d0c4ff
plot $p colour live 16r178f86ff
plot $p colour accent 16rb85c38ff

t 'pack forget .f'
t 'frame .par'
t 'frame .but'
t 'button .but.quit -text Quit -command {send ev quit}'
t 'label .but.at -text {} -anchor w -width 440'
t 'pack .but.quit -side left'
t 'pack .but.at -side left -padx 10'
t 'pack .but -side bottom -fill x'
t 'pack .par -side bottom -fill x'
t 'label .par.lc -text {cutoff}'
t 'scale .par.cut -from 0.02 -to 0.48 -resolution 0.01 -orient horizontal -length 240 -showvalue 1 -command {send ev param}'
t '.par.cut set 0.15'
t 'grid .par.lc -row 0 -column 0 -sticky w -padx 4'
t 'grid .par.cut -row 0 -column 1 -sticky w'
t 'label .par.lw -text {window}'
t 'frame .par.win'
t 'radiobutton .par.win.r -text rect -value rect -variable win -command {send ev param}'
t 'radiobutton .par.win.h -text hann -value hann -variable win -command {send ev param}'
t 'radiobutton .par.win.b -text blackman -value blackman -variable win -command {send ev param}'
t 'pack .par.win.r .par.win.h .par.win.b -side left'
# `variable', not `set': Inferno's Tk has no set command, and variable
# is how a radiobutton's variable is read and written from a script
t 'variable win hann'
t 'grid .par.lw -row 1 -column 0 -sticky w -padx 4'
t 'grid .par.win -row 1 -column 1 -sticky w'
t 'pack .f -side top -fill both -expand 1'
t update
plot $p namechan ev
plot $p fit

# the signal itself never changes; only what is done to it does
signal $raw length $N
signal $raw tone 2.0 0.0625
signal $raw tone 0.4 0.3125
signal $raw noise 0.25 7

fn rebuild {
	cut := ${plot $p tk '.par.cut get'}
	win := ${plot $p tk 'variable win'}

	# a fresh copy of the signal each time: `filter' works in place
	signal $work data ${signal $raw samples}
	signal $work fir lowpass 63 $cut hamming
	signal $work filter
	signal $work spectrum $win
	plot $p spec clear
	plot $p spec append ${signal $work trace}
	pk := ${signal $work peak}

	signal $work response 200
	plot $p resp clear
	plot $p resp append ${signal $work trace}

	plot $p wave clear
	plot $p wave append ${signal $work waveform}

	plot $p clear
	plot $p content margin 55 22 18 30
	plot $p split content y wave 1 spec 2 gutter 34
	plot $p view w wave
	plot $p scale w x 0 200
	plot $p scale w y -3 3 reverse
	plot $p axis w x sample
	plot $p axis w y amplitude
	plot $p line w wave x n y v colour live width 1
	plot $p view s spec
	plot $p scale s x 0 0.5
	plot $p scale s y 0 2.2 reverse
	plot $p axis s x 'cycles per sample'
	plot $p axis s y power
	plot $p line s resp f mag colour grid width 1
	plot $p line s spec f power colour accent width 2
	plot $p draw
	t '.but.at configure -text {cutoff '^$cut^'  window '^$win^'  peak at '^${hd $pk}^'}'
}

rebuild
while {} {
	ev := ${plot $p recv ev 200}
	if {! no $ev} {
		e := ${split $ev}
		what := ${hd $e}
		if {~ $what quit exit} {
			exit
		}
		if {~ $what param} {
			rebuild
		}
		if {! ~ $what quit exit param} {
			plot $p winctl ${join ' ' $e}
		}
	}
}
