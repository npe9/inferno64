#!/bin/sh
#
# The measurement lil(1) was built on, made instead of assumed.
#
# The claim is that a shell on this board dies under repeated ctl writes
# because each one forks -- a process for the command and an open for
# the redirection -- and that a language which holds the file in a
# variable does not.  Both halves are testable without hardware, because
# the failure is in the Dis pool and not in the radio.
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
# This is a comparison and not a demonstration: the shell run is the
# control, and if it survives too then forking was never the problem and
# lil is not justified by this.
#
#	lilvsh.sh <qemu-system-arm> [kernel] [iterations]
#
Q=${1:?usage: lilvsh.sh <qemu-system-arm> [kernel] [count]}
K=${2:-os/inferno/stm32f407/istm32f407}
N=${3:-40}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0

# Both runs write this, N times, one every two seconds.
LINE='rssioffset -90'

shrun() {
	{ sleep 12
	  printf 'cat /dev/memory\n'; sleep 3
	  i=0
	  while [ $i -lt $N ]; do
		printf "echo $LINE >/dev/radio0/ctl\n"
		sleep 2
		i=$((i+1))
	  done
	  printf 'echo SH-SURVIVED\n'; sleep 3
	  printf 'cat /dev/memory\n'; sleep 4
	} | timeout -s KILL $((N*2+60)) "$Q" -M netduinoplus2,radio=on \
		-nographic -serial null -serial mon:stdio -kernel "$K" 2>&1
}

lilrun() {
	{ sleep 12
	  printf 'lil\n'; sleep 4
	  printf 'print(slurp("/dev/memory"))\n'; sleep 4
	  printf 'ctl := open("/dev/radio0/ctl", "w")\n'; sleep 3
	  printf 'timelimit(0)\n'; sleep 2
	  printf 'n := 0\n'; sleep 2
	  # One statement.  No fork, no open, and the file stays open
	  # across every write -- which is the whole point.
	  printf 'while (n < %d) { write(ctl, "%s"); sleep(2000); n = n + 1 }\n' \
		$N "$LINE"
	  sleep $((N*2+15))
	  printf 'print("LIL-SURVIVED n=", n)\n'; sleep 4
	  printf 'print(slurp("/dev/memory"))\n'; sleep 4
	} | timeout -s KILL $((N*2+90)) "$Q" -M netduinoplus2,radio=on \
		-nographic -serial null -serial mon:stdio -kernel "$K" 2>&1
}

echo "=== $N writes of \"$LINE\", one every two seconds ==="
echo
echo "--- through the shell, one fork and one open each ---"
shrun > "$OUT/sh" 2>&1
grep -E 'SH-SURVIVED|no procs|out of memory|arena|Broken|heap' "$OUT/sh" |
	sed 's/^/   /' | head -12
grep -c "$LINE" "$OUT/sh" | sed 's/^/   ctl lines seen: /'
echo
echo "--- through lil, one open held across all of them ---"
lilrun > "$OUT/lil" 2>&1
grep -E 'LIL-SURVIVED|no procs|out of memory|arena|Broken|heap' "$OUT/lil" |
	sed 's/^/   /' | head -12
echo
if grep -q SH-SURVIVED "$OUT/sh" && grep -q LIL-SURVIVED "$OUT/lil"; then
	echo "BOTH SURVIVED -- forking is not the limit at this rate, and this"
	echo "run does not justify lil.  Raise the count and try again."
elif grep -q LIL-SURVIVED "$OUT/lil"; then
	echo "LIL SURVIVED, SH DID NOT -- which is the claim."
elif grep -q SH-SURVIVED "$OUT/sh"; then
	echo "SH SURVIVED AND LIL DID NOT -- lil is worse here; find out why"
	echo "before believing anything else in man/1/lil."
else
	echo "NEITHER SURVIVED -- the limit is not what lil addresses."
fi
