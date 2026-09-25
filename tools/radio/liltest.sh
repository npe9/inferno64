#!/bin/sh
#
# lil(1) against the kernel it is for, not against the host emu.
#
# The host emu is the wrong instrument for this twice over.  It runs a
# 64-bit Dis tree where the board runs a 32-bit one, and its allocator
# behaves differently: a compiled Limbo loop whose body is only
# "t := s[1:]" freed 15 times in 20000 allocations under the host emu and
# died having extended the arena rather than collected, where the board's
# kernel frees every one.  So a lil feature that works under emu is not
# thereby known to work on the board, and a memory figure taken under emu
# is not evidence about the board at all.
#
# Each case prints a token this script greps for.  A case that does not
# print its token failed, whether it printed something else or nothing --
# so a crash, a hang and a wrong answer all read as a failure, and a
# silently-skipped case cannot read as a pass.
#
# INPUT IS PACED, and must be: the console echoes each character from the
# uart interrupt handler and queues it for the reader separately, so a
# line typed faster than it echoes comes back complete in the echo and
# arrives short at the program.  An unpaced 57-character loop lost its
# closing brace here.
#
# create() AND A WRITABLE FILE ARE NOT TESTED HERE, because this board
# has nowhere to write.  Its root is devroot, which is served read-only
# out of flash, and nothing binds a ram file system over it: the shell
# gets "cannot open /tmp/shtest: permission denied" for a redirection
# into /tmp, and lil gets "cannot create".  An earlier version of this
# script wrote a file in /tmp and read it back, and the three cases that
# failed were the script's fault and not lil's.  Those paths are covered
# under the host emu instead, and write() is exercised here against the
# radio's ctl file, which is the write that matters on this board anyway.
#
#	liltest.sh <qemu-system-arm> [kernel]
#
Q=${1:?usage: liltest.sh <qemu-system-arm> [kernel]}
K=${2:-os/inferno/stm32f407/istm32f407}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' 0

cat > "$OUT/pace.py" <<'PYEOF'
import sys, time
for line in sys.stdin:
    for ch in line:
        sys.stdout.write(ch); sys.stdout.flush(); time.sleep(0.02)
PYEOF

# Each line, and the token that says it worked.  The negative controls
# matter as much: a token printed by a branch that should not run, or by
# a statement that should have failed, is a failure too.
script() {
	sleep 14; printf 'lil\n'; sleep 5
	set -- \
	 'x := 42' \
	 'print("T-int ", x)' \
	 'print("T-hex ", 0x2a, " ", 16r2a)' \
	 'print("T-neg ", -104, " ", 7 - -3)' \
	 'print("T-str ", "a" + "b")' \
	 'print("T-cmp ", 3 < 4, " ", 9 < 4, " ", "a" == "a")' \
	 'print("T-len ", len("abcde"))' \
	 'print("T-ms ", millisec() > 0)' \
	 'if (x == 42) { print("T-then") }' \
	 'else { print("F-else-after-taken") }' \
	 'if (x == 9) { print("F-then") }' \
	 'else { print("T-else") }' \
	 'if (x == 42) { print("T-inline") } else { print("F-inline") }' \
	 'n := 0' \
	 'while (n < 3) { n = n + 1 }' \
	 'print("T-while ", n)' \
	 'y = 1' \
	 'print("T-after-baddecl")' \
	 'print("T-slurp ", len(slurp("/dev/time")) > 0)' \
	 'g := open("/dev/time")' \
	 'print("T-read ", len(read(g, 8)))' \
	 'print("T-read2 ", len(read(g, 8)))' \
	 'close(g)' \
	 'print("F-read-after-close ", read(g, 8))' \
	 'print("T-after-closed-read")' \
	 'print("T-dir ", dir("/"))' \
	 'print("T-bind ", bind("#W", "/dev", "a"))' \
	 'print("T-radio ", slurp("/dev/radio0/stats"))' \
	 'c := open("/dev/radio0/ctl", "w")' \
	 'print("T-ctl ", write(c, "rate 9600"))' \
	 'print("T-ctl2 ", write(c, "bw 50000"))' \
	 'print("T-tl ", timelimit())' \
	 'nosuch(1)' \
	 'print("T-after-badcall")' \
	 'print("T-END")'
	for l in "$@"; do
		printf '%s\n' "$l"
		sleep 3
	done
	sleep 4
}

script | python3 "$OUT/pace.py" | timeout -s KILL 300 "$Q" \
	-M netduinoplus2,radio=on -nographic -serial null -serial mon:stdio \
	-kernel "$K" > "$OUT/log" 2>&1

# The tokens that must appear, and the ones that must not.  A "T-" token
# is counted twice in the transcript -- the echo of the line that asks
# for it, and the line printing it -- so two or more is a pass and one is
# an echo with nothing behind it.
PASS='T-int T-hex T-neg T-str T-cmp T-len T-ms T-then T-else T-inline
      T-while T-after-baddecl T-slurp T-read T-read2 T-after-closed-read
      T-dir T-bind T-radio T-ctl T-ctl2 T-tl T-after-badcall T-END'
FAIL='F-else-after-taken F-then F-inline F-read-after-close'

bad=0
for t in $PASS; do
	# Anchored on a non-token character, and both halves of that were
	# got wrong once.  Matching loosely passed "T-w" on the strength of
	# "T-while", on a line that had actually printed "lil: f is not
	# set"; anchoring on a space or end of line then failed every token
	# printed as print("T-then"), where what follows it is a quote.
	n=$(grep -cE -- "${t}([^A-Za-z0-9_-]|\$)" "$OUT/log")
	if [ "$n" -ge 2 ]; then
		printf '  ok      %s\n' "$t"
	else
		printf '  FAILED  %s (seen %s times; 1 is the echo alone)\n' "$t" "$n"
		bad=$((bad+1))
	fi
done
for t in $FAIL; do
	# A branch that must not run, so its token must appear once -- the
	# echo of the line that mentions it -- and never twice.
	n=$(grep -cE -- "${t}([^A-Za-z0-9_-]|\$)" "$OUT/log")
	if [ "$n" -le 1 ]; then
		printf '  ok      %s did not run\n' "$t"
	else
		printf '  FAILED  %s RAN and must not have\n' "$t"
		bad=$((bad+1))
	fi
done
# And the two errors that must be reported rather than swallowed.
for m in 'is not set; use :=' 'is not a builtin' 'read wants an open file'; do
	if grep -q -- "$m" "$OUT/log"; then
		printf '  ok      reported: %s\n' "$m"
	else
		printf '  FAILED  never reported: %s\n' "$m"
		bad=$((bad+1))
	fi
done
if grep -qE 'Broken|allocb: no memory|panic' "$OUT/log"; then
	printf '  FAILED  the kernel or the shell broke during the run\n'
	grep -E 'Broken|allocb: no memory|panic' "$OUT/log" | sed 's/^/          /'
	bad=$((bad+1))
fi
echo
if [ $bad = 0 ]; then
	echo "LILTEST-OK  every case on the stm32f407 kernel"
else
	echo "LILTEST-FAILED  $bad"
	cp "$OUT/log" "${LOGTO:-/tmp}/liltest.log"
	echo "transcript at ${LOGTO:-/tmp}/liltest.log"
fi
exit $bad
