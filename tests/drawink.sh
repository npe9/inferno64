#!/bin/sh
#
# Run drawink(1) under the host's emu and require every check to pass.
#
#	sh tests/drawink.sh
#
# WHY A WRAPPER.  drawink draws known geometry into the screen image and
# reads it back out of the screen image, so it is the one check that
# distinguishes "memdraw ran" from "the pixels are where memdraw put
# them".  On the host that is a shadow buffer and the test is about the
# drawing; on a board with a direct framebuffer the readback comes out of
# video RAM and it is about the display too.  This script is the host
# half, which is the half that can run unattended.
#
# The board half is a command, not a script, because it needs a board:
#
#	sh tools/jtag/kinstall.sh
#	... then on the board ...
#	bind /n/remote/dis /dis; drawink
#
# and the numbers from the two are compared BY HAND, on purpose: the
# agreement that matters is the glyph ink, and "226 of 1728 inked, ink
# box 9,10 to 71,21" is a sentence a person checks against the other
# machine's output, not a threshold.  Writing it into this script would
# fix the host's font and resolution into a board test.
#
# EMU, NOT emu-cpu.  This needs a screen, so it needs the Cocoa build.
# A machine with no display cannot run this, which is why it is not in
# any suite that must pass everywhere.
#
set -u
ROOT=${ROOT:-`cd \`dirname "$0"\`/.. && pwd`}
EMU=${EMU:-$ROOT/MacOSX/arm64/bin/emu-cocoa}
OUT=${OUT:-${TMPDIR:-/tmp}/drawink-$$.log}

if [ ! -x "$EMU" ]; then
	echo "drawink: no emu at $EMU (set EMU=)" >&2
	exit 2
fi
if [ ! -f "$ROOT/dis/drawink.dis" ]; then
	echo "drawink: no $ROOT/dis/drawink.dis -- (cd appl/cmd && mk install)" >&2
	exit 2
fi

"$EMU" -c0 -r"$ROOT" /dis/drawink.dis > "$OUT" 2>&1
rc=$?
sed 's/^/  /' "$OUT"

#
# Both conditions, and the second is the one that matters.
#
# "all checks passed" on its own would also be printed by a drawink that
# had SKIPPED everything -- it counts failures, not checks.  So require
# the five PASS lines as well.  This is the same trap the suite it tests
# records: a test that cannot fail reports success.
#
npass=`grep -c ' PASS ' "$OUT" 2>/dev/null || true`
if [ "$rc" = 0 ] && grep -q 'all checks passed' "$OUT" && [ "$npass" = 5 ]; then
	echo "DRAWINK-OK ($npass checks)"
	rm -f "$OUT"
	exit 0
fi
echo "DRAWINK-FAILED (exit $rc, $npass of 5 PASS lines) -- log in $OUT" >&2
exit 1
