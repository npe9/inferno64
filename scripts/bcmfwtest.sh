#!/bin/sh
#
# Load a patch into the controller model and check what came back.
#
# bt/bcmfw drives a Broadcom part through the sequence that gives it
# working firmware: Download Minidriver, a run of Write RAM records from
# an .hcd file, Launch RAM, and a reset afterwards.  The Raspberry Pi
# 3B's radio is the reason it exists, and the board is the only place
# the real thing can be tested -- but everything about the sequence
# except the silicon can be tested here, in seconds, against
# scripts/bthci.py.
#
# Two things the model does on purpose, both because the board did them
# first:
#
#	it refuses a Write RAM that arrives before the minidriver, so a
#	loader that sent the records in the wrong order would fail here
#	rather than on a board;
#
#	and it restarts after Launch RAM the way the real part does,
#	putting zero bytes on the wire before it answers anything.  That
#	is what made the first version of bcmfw give up on the Pi -- "bad
#	H4 packet indicator 0x00" from a controller that was merely still
#	coming back.  Remove the resync from bcmfw and this script fails
#	with that same line; it was checked that way.
#
# The address is the verdict.  A cold model answers Read BD_ADDR with
# one address and a patched one with another, so a loader that reported
# success without loading anything would be caught by reading it back.
#
set -e
ROOT=${ROOT:-`cd \`dirname $0\`/.. && pwd`}
EMU=${EMU:-$ROOT/MacOSX/arm64/bin/emu}
PORT=${PORT:-5597}
OUT=${OUT:-`mktemp -d`}
PATCHED=4300deadbeef		# what bthci.py's address becomes once patched

[ -x "$EMU" ] || { echo "bcmfwtest: no emu at $EMU (set EMU=)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "bcmfwtest: no python3" >&2; exit 2; }

# two names for one file: the host writes it, and emu sees the tree
# rooted at $ROOT, so the program is given the name from inside
hcd="$ROOT/tmp/bcmfwtest.hcd"
inner=/tmp/bcmfwtest.hcd
mkdir -p "$ROOT/tmp"
python3 - "$hcd" <<'PY'
import struct, sys
# the format is the commands themselves: opcode, length, parameters
recs = []
for i in range(8):
	payload = bytes([i]) * 64
	recs.append(struct.pack('<HB', 0xfc4c, len(payload)) + payload)
recs.append(struct.pack('<HB', 0xfc4e, 4) + bytes(4))	# Launch RAM last
open(sys.argv[1], 'wb').write(b''.join(recs))
PY

status=0
pkill -f "bthci.py $PORT" 2>/dev/null || true
python3 "$ROOT/scripts/bthci.py" $PORT > "$OUT/model.log" 2>&1 &
model=$!
sleep 2
"$EMU" -c0 -r "$ROOT" /dis/bt/bcmfw.dis "tcp!127.0.0.1!$PORT" "$inner" \
	> "$OUT/bcmfw.log" 2>&1 || true
kill $model 2>/dev/null || true
wait $model 2>/dev/null || true

cat "$OUT/bcmfw.log"
if ! grep -q "BCMFW-OK 9 records" "$OUT/bcmfw.log"; then
	echo "BCMFW-TEST-FAIL the load did not finish"
	status=1
elif ! grep -q "controller address $PATCHED" "$OUT/bcmfw.log"; then
	echo "BCMFW-TEST-FAIL the controller's address is not the patched one"
	status=1
elif ! grep -q "patch loaded, 8 records, restarting" "$OUT/model.log"; then
	echo "BCMFW-TEST-FAIL the model did not see eight Write RAM records"
	sed -n 1,20p "$OUT/model.log"
	status=1
else
	echo "BCMFW-TEST-OK 9 records, restart survived, address read back patched"
fi
rm -f "$hcd"
exit $status
