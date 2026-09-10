#!/dis/sh
# leap - a side-scrolling platformer, entirely in sh(1).
#
# warren(1) showed a game could be written in the shell.  This one shows
# the parts warren did not need: gravity and a jump, a level wider than
# the window scrolled under it, and a list of things that move on their
# own.  All three turn on what the shell already has and I had to go and
# find - ${index}, ${split}, ${join} from sh-std(1), and expr(1)'s
# reverse-Polish arithmetic - so an entity is a string "x,y,dir" and a
# swarm is a list of them, rebuilt each frame.
#
#	sh /lib/tiles/leap.sh
#
# Arrow keys or wasd to run, Space or w to jump, Esc or q to stop.
load std
load expr
load tiles

id = ${tiles new 256x96 3 leap}

tiles $id palette brick dark.black dark.orange mid.orange light.orange
tiles $id palette turf  dark.black dark.green  mid.lime   light.lime
tiles $id palette soil  dark.black dark.orange dark.red   mid.orange
tiles $id palette coin  dark.black dark.yellow pale.yellow mid.yellow
tiles $id palette skin  dark.black dark.red    pale.yellow mid.azure
tiles $id palette foe   dark.black dark.violet mid.magenta light.rose
tiles $id palette hud   dark.black pale.grey   pale.grey  pale.grey

tiles $id sheet art /lib/tiles/demo.chr
tiles $id font font
tiles $id surface level 512 96 mid.azure
tiles $id surface screen 256 96 mid.azure
tiles $id map level art /lib/tiles/leap.map

tiles $id bind left  Left  a
tiles $id bind right Right d
tiles $id bind jump  Space w Up
tiles $id bind quit  Esc   q

# Is the pixel (x, y) inside something solid?  at(2) answers in tiles,
# so this is the one place the two coordinate systems meet.
subfn solid {
	c = ${tiles $id at level ${expr $1 8 /} ${expr $2 8 /}}
	if {~ $c '#' '=' '-'} { result = 1 } { result = 0 }
}

px = 16
py = 56
vy = 0
ground = 0
score = 0
running = 1
# x,y,direction - a walker apiece, and the list is the swarm
foes = 168,72,-1 272,72,1 400,72,-1

while {~ $running 1} {
	# blocks until a key or until the frame is due
	ev = ${tiles $id wait 55}
	ks = ${tiles $id keys}
	if {~ $ks quit} { running = 0 }

	# --- across.  Both edges of the player are tested, or a run into
	# --- a wall stops only when the left edge reaches it.
	nx = $px
	if {~ $ks left}  { nx = ${expr $px 3 -} }
	if {~ $ks right} { nx = ${expr $px 3 +} }
	if {~ ${expr $nx 0 lt} 1} { nx = 0 }
	blocked = 0
	if {~ ${solid $nx ${expr $py 2 +}} 1} { blocked = 1 }
	if {~ ${solid ${expr $nx 7 +} ${expr $py 2 +}} 1} { blocked = 1 }
	if {~ ${solid $nx ${expr $py 7 +}} 1} { blocked = 1 }
	if {~ ${solid ${expr $nx 7 +} ${expr $py 7 +}} 1} { blocked = 1 }
	if {~ $blocked 0} { px = $nx }

	# --- and down.  A jump is only allowed from the ground, which is
	# --- what stops it being a flap.
	if {~ $ks jump} { if {~ $ground 1} { vy = -11 } }
	vy = ${expr $vy 1 +}
	if {~ ${expr $vy 8 gt} 1} { vy = 8 }
	ny = ${expr $py $vy +}
	ground = 0
	if {~ ${expr $vy 0 gt} 1} {
		feet = ${expr $ny 8 +}
		land = 0
		if {~ ${solid $px $feet} 1} { land = 1 }
		if {~ ${solid ${expr $px 7 +} $feet} 1} { land = 1 }
		if {~ $land 1} {
			py = ${expr ${expr ${expr $feet 8 /} 8 '*'} 8 -}
			vy = 0
			ground = 1
		} { py = $ny }
	} { py = $ny }
	# off the bottom: back to the start
	if {~ ${expr $py 100 gt} 1} { px = 16; py = 56; vy = 0 }

	# --- a coin under the player is taken and cleared from the level
	tx = ${expr ${expr $px 4 +} 8 /}
	ty = ${expr ${expr $py 4 +} 8 /}
	if {~ ${tiles $id at level $tx $ty} o} {
		tiles $id set level $tx $ty blank
		score = ${expr $score 10 +}
	}

	# --- the camera keeps the player a third in and stops at the ends
	cam = ${expr $px 96 -}
	if {~ ${expr $cam 0 lt} 1} { cam = 0 }
	if {~ ${expr $cam 256 gt} 1} { cam = 256 }

	tiles $id view level screen $cam 0

	# --- the walkers.  The list is rebuilt rather than mutated,
	# --- because the shell has no way to assign to one element of one.
	nf = ()
	for f in $foes {
		p = ${split , $f}
		fx = ${index 1 $p}
		fy = ${index 2 $p}
		fd = ${index 3 $p}
		ax = ${expr $fx $fd +}
		lead = ${expr $ax 4 +}
		if {~ ${expr $fd 0 lt} 1} { lead = ${expr $ax 4 -} }
		turn = 0
		if {~ ${solid $lead ${expr $fy 4 +}} 1} { turn = 1 }
		if {~ ${solid $lead ${expr $fy 12 +}} 0} { turn = 1 }
		if {~ $turn 1} { fd = ${expr 0 $fd -}; ax = $fx }
		nf = $nf ${join , $ax $fy $fd}
		sx = ${expr $ax $cam -}
		if {~ ${expr $sx 8 '*' 0 gt} 1} {
			tiles $id put screen $sx $fy art 6 foe
		}
		# walked into: back to the start
		dx = ${expr $px $ax -}
		if {~ ${expr $dx 0 lt} 1} { dx = ${expr 0 $dx -} }
		dy = ${expr $py $fy -}
		if {~ ${expr $dy 0 lt} 1} { dy = ${expr 0 $dy -} }
		if {~ ${expr $dx 7 lt} 1} {
			if {~ ${expr $dy 7 lt} 1} {
				px = 16; py = 56; vy = 0
			}
		}
	}
	foes = $nf

	tiles $id put screen ${expr $px $cam -} $py art 6 skin
	tiles $id text screen 8 0 hud SCORE $score
	tiles $id draw screen
}
