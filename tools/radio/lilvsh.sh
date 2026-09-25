#!/bin/sh
#
# The measurement lil(1) was built on, made instead of assumed.
#
# The claim is that a shell on this board dies under repeated ctl writes
# because each one forks -- a process for the command and an open for
# the redirection -- and that a language holding the file in a variable
# does not.  Both halves are testable without hardware, because the
# failure is in the Dis pool and not in the radio.
#
# The failure being reproduced is on record twice.  The board's own
# configuration file has it as
#
#	; echo rssioffset -90 >/dev/radio0/ctl
#	arena too large: main size 4096 cursize 74816 ...
#	no procs for kproc
#
# and tools/radio/board.py has it from the other side: "a monitor
# running one probe every two seconds killed the shell in a few
# minutes".  So the two runs below write the same ctl line the same
# number of times at the same spacing, one through the shell and one
# through lil, and print what each pool looked like afterwards.
#
# THIS IS A COMPARISON AND NOT A DEMONSTRATION.  The shell run is the
# control.  At 30 writes of "rssioffset -90" the shell survives with its
# live heap unmoved -- 358 objects before, 363 after -- so at that rate
# forking is not the limit and nothing here justifies lil.  That is why
# the count is a parameter and why the script says which way it went
# rather than announcing a winner.
#
# INPUT IS PACED ONE CHARACTER AT A TIME, and must be.  The console
# echoes each character from the uart interrupt handler and queues it
# for the reader separately, so a line typed faster than it echoes comes
# back complete in the echo and arrives short at the program.  An
# unpaced 57-character loop lost its closing brace, which lil reported
# by staying on its continuation prompt; the shell gives a parse error.
# Either way the run measures nothing.
#
#	lilvsh.sh <qemu-system-arm> [kernel] [count] [spacing-seconds]
#
Q=${1:?usage: lilvsh.sh <qemu-system-arm> [kernel] [count] [spacing]}
K=${2:-os/inferno/stm32f407/istm32f407}
N=${3:-90}
GAP=${4:-2}
LINE=${LINE:-'rssioffset -90'}
OUT=${OUTDIR:-$(mktemp -d)}
mkdir -p "$OUT"

PACE=$OUT/pace.py
cat > "$PACE" <<'PYEOF'
import sys, time
for line in sys.stdin:
    for ch in line:
        sys.stdout.write(ch); sys.stdout.flush(); time.sleep(0.02)
PYEOF

boot() {	# qemu with the console on stdio, paced
	python3 "$PACE" | timeout -s KILL "$1" "$Q" -M netduinoplus2,radio=on \
		-nographic -serial null -serial mon:stdio -kernel "$K" 2>&1
}

shrun() {
	{ sleep 14
	  printf 'cat /dev/memory\n'; sleep 4
	  i=0
	  while [ $i -lt $N ]; do
		printf "echo $LINE >/dev/radio0/ctl\n"
		sleep $GAP
		i=$((i+1))
	  done
	  sleep 3
	  printf 'echo SH-SURVIVED\n'; sleep 4
	  printf 'cat /dev/memory\n'; sleep 5
	} | boot $((N*GAP+120))
}

lilrun() {
	{ sleep 14
	  printf 'lil\n'; sleep 5
	  printf 'print(slurp("/dev/memory"))\n'; sleep 6
	  printf 'ctl := open("/dev/radio0/ctl", "w")\n'; sleep 5
	  printf 'timelimit(0)\n'; sleep 4
	  printf 'n := 0\n'; sleep 3
	  # One statement.  No fork, no open, and the file stays open
	  # across every write, which is the whole point.
	  printf 'while (n < %d) { write(ctl, "%s"); sleep(%d); n = n + 1 }\n' \
		$N "$LINE" $((GAP*1000))
	  sleep $((N*GAP+25))
	  printf 'print("LIL-SURVIVED n=", n)\n'; sleep 5
	  printf 'print(slurp("/dev/memory"))\n'; sleep 6
	} | boot $((N*GAP+200))
}

# live heap objects = allocations made minus frees made, columns 4 and 5
# of /dev/memory's heap line.  cursize alone hides a leak that fits in
# what the pool already holds.
report() {
	awk '/heap/ { printf "   heap cursize %s  live %d  (alloc %s free %s)\n", \
		$1, $4-$5, $4, $5 }' "$1"
}

echo "=== $N writes of \"$LINE\", one every ${GAP}s, paced ==="
echo
echo "--- through the shell: one fork and one open each ---"
shrun > "$OUT/sh" 2>&1
report "$OUT/sh"
grep -E 'no procs|out of memory|arena|Broken' "$OUT/sh" | sed 's/^/   /' | head -6
grep -c "SH-SURVIVED" "$OUT/sh" | sed 's/^/   SH-SURVIVED seen: /'
echo
echo "--- through lil: one open held across all of them ---"
lilrun > "$OUT/lil" 2>&1
report "$OUT/lil"
grep -E 'no procs|out of memory|arena|Broken' "$OUT/lil" | sed 's/^/   /' | head -6
grep -E 'LIL-SURVIVED' "$OUT/lil" | sed 's/^/   /' | tail -2
echo
s=0; l=0
grep -q SH-SURVIVED "$OUT/sh" && s=1
grep -q 'LIL-SURVIVED n=' "$OUT/lil" && l=1
if [ $s = 1 ] && [ $l = 1 ]; then
	echo "BOTH SURVIVED.  At this rate and count forking is not the limit,"
	echo "and this run does not justify lil.  Raise the count."
elif [ $l = 1 ]; then
	echo "LIL SURVIVED, SH DID NOT.  That is the claim, measured."
elif [ $s = 1 ]; then
	echo "SH SURVIVED AND LIL DID NOT.  lil is worse here; find out why"
	echo "before believing anything in man/1/lil."
else
	echo "NEITHER SURVIVED.  The limit is not the one lil addresses."
fi
echo
echo "transcripts in $OUT"
