#!/dis/sh
# warren - a maze game, entirely in sh(1).
#
# There is no Limbo in this file and none behind it that was written for
# this game.  tiles(2) draws from named palettes, sheets and surfaces
# made by text; the art and the level are files; sh-tiles(1) forwards
# commands to it, answers questions in ${}, reads the keyboard through
# keyhold(2) and paces the frames.  What is left over is the rules, and
# the rules of a maze game are twenty lines of shell.
#
#	sh /lib/tiles/warren.sh
#
# Arrow keys or wasd, Esc or q to stop.
load std
load expr
load tiles

id = ${tiles new 256x96 3 warren}

tiles $id palette wall  dark.black dark.azure  mid.cyan    light.cyan
tiles $id palette coin  dark.black dark.yellow pale.yellow mid.yellow
tiles $id palette floor dark.black dark.grey   dark.grey   dark.grey
tiles $id palette skin  dark.black dark.red    pale.yellow mid.azure
tiles $id palette hud   dark.black pale.grey   pale.grey   pale.grey

tiles $id sheet art /lib/tiles/demo.chr
tiles $id font font
tiles $id surface level 256 96 dark.black
tiles $id surface screen 256 96 dark.black
tiles $id map level art /lib/tiles/warren.map

tiles $id bind left  Left  a
tiles $id bind right Right d
tiles $id bind up    Up    w
tiles $id bind down  Down  s
tiles $id bind quit  Esc   q

x = 1
y = 1
score = 0
coins = 12
running = 1

while {~ $running 1} {
	# ${...} and not `{...}: a backquote runs the block in a
	# subprocess, and a subprocess reaching into the parent's Tk
	# window deadlocks.  The sbuiltin answers in this process.
	ks = ${tiles $id keys}
	if {~ $ks quit} { running = 0 }

	nx = $x
	ny = $y
	if {~ $ks left}  { nx = ${expr $x 1 -} }
	if {~ $ks right} { nx = ${expr $x 1 +} }
	if {~ $ks up}    { ny = ${expr $y 1 -} }
	if {~ $ks down}  { ny = ${expr $y 1 +} }

	# the level answers what is in the way
	c = ${tiles $id at level $nx $ny}
	if {! ~ $c '#'} {
		x = $nx
		y = $ny
		if {~ $c o} {
			tiles $id set level $x $y .
			score = ${expr $score 10 +}
			coins = ${expr $coins 1 -}
		}
	}

	tiles $id blit level screen 0 0
	tiles $id put screen ${expr $x 8 '*'} ${expr $y 8 '*'} art 6 skin
	tiles $id text screen 8 0 hud SCORE $score
	if {~ $coins 0} { tiles $id text screen 80 40 hud ALL COINS }
	tiles $id draw screen
	tiles $id pace 110
}
