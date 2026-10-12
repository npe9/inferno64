#!/bin/sh
#
# Does tools/jtag/splittrace decode a Splitev record correctly?
#
#	sh tests/splittrace.sh
#
# WHY A TEST FOR A READER.  The reader is the whole instrument: the
# kernel side stores raw registers and formats nothing, so every field
# name, bit position and shift in the output is this script's opinion.
# A wrong shift prints a plausible endpoint number for a real record,
# which is the failure mode this tree has paid for repeatedly -- a wrong
# number that looks right.  So the decoder is fed records whose decoded
# form is known in advance and the output is compared against it.
#
# IT TESTS THE REAL TEXT.  The python half lives in a heredoc inside
# splittrace, and this extracts that heredoc rather than keeping a copy
# -- a copy would pass while the tool it is standing in for was broken.
#
# AND IT TESTS THE RING ARITHMETIC, which is the one piece of logic
# here that is not a shift: with nsplitev past the cap, entry k lives at
# k % cap and the oldest live entry is nsplitev - cap.  Get that wrong
# and the output is a correct decode of the records in the wrong order,
# which reads as the hardware doing something strange.
#
set -u
HERE=`cd \`dirname "$0"\` && pwd`
ROOT=`cd "$HERE/.." && pwd`
TOOL=$ROOT/tools/jtag/splittrace
T=${TMPDIR:-/tmp}/splittrace-test.$$
trap 'rm -rf "$T"' 0 1 2 15
mkdir -p "$T"

if [ ! -r "$TOOL" ]; then
	echo "splittrace.sh: no $TOOL" >&2
	exit 2
fi

#
# Extract the decoder.  The start marker is the line that OPENS the
# heredoc -- not the `exec python3' line, which is continued onto a
# second line with a backslash, so starting there picked up the
# continuation as python and produced an IndentationError.  Everything
# between the opening and the lone DECODER that closes it is the
# program.
#
# AND THE TAG IS `DECODER', NOT `PYEOF'.  splittrace has two python
# heredocs -- the kerndate reader and this -- and both opened with
# PYEOF, so matching on that extracted the FIRST one and handed awk's
# own quoting to python.  The decoder's tag was renamed so the match
# can only mean one block.
#
awk '
	!inhdr && /<<.DECODER.$/ { inhdr=1; next }
	inhdr && /^DECODER$/	{ exit }
	inhdr			{ print }
' "$TOOL" >"$T/dec.py"

if [ ! -s "$T/dec.py" ]; then
	echo "splittrace.sh: could not extract the decoder from $TOOL" >&2
	echo "splittrace.sh: the heredoc marker or the exec line changed." >&2
	echo "splittrace.sh: THIS IS A FAILURE, not a skip: an extractor" >&2
	echo "splittrace.sh: that silently matches nothing would make this" >&2
	echo "splittrace.sh: test pass for ever without running anything." >&2
	exit 2
fi

#
# The fixtures.  Field order is hfnum hcchar hcsplt hcint hctsiz hcdma
# chan tag, packed "<6I2H4x" -- 32 bytes, which is what 7c makes the
# struct and what usbdwc.c's splitevsize[] asserts.
#
python3 - "$T" <<'PYEOF'
import struct, sys
T = sys.argv[1]
FMT = "<6I2H4x"
assert struct.calcsize(FMT) == 32

def rec(hfnum, hcchar, hcsplt, hcint, hctsiz, hcdma, chan, tag):
    return struct.pack(FMT, hfnum, hcchar, hcsplt, hcint, hctsiz, hcdma,
                       chan, tag)

# A low-speed control IN on device 5 endpoint 0, channel 3, in frame
# 1000 microframe 2, one 8-byte packet, DATA1, complete-split phase,
# answered Xfercomp|Chhltd|Ack.
#   hcchar: Devaddr 5<<22 | Epnum 0<<11 | Epin 1<<15 | Lspddev 1<<17
#           | Eptype ctl 0<<18 | Mps 8
#   hcsplt: Spltena 1<<31 | Compsplt 1<<16 | Hubaddr 1<<7 | Prtaddr 4
#   hctsiz: Pid DATA1 2<<29 | Pktcnt 1<<19 | 8
#   hfnum:  1000<<3 | 2
ctl = [
    rec(1000 << 3 | 2,
        5 << 22 | 0 << 11 | 1 << 15 | 1 << 17 | 0 << 18 | 8,
        1 << 31 | 1 << 7 | 4,
        0, 2 << 29 | 1 << 19 | 8, 0xc4001000, 3, 1),          # SS-ARM
    rec(1000 << 3 | 3,
        5 << 22 | 0 << 11 | 1 << 15 | 1 << 17 | 0 << 18 | 8,
        1 << 31 | 1 << 7 | 4,
        (1 << 1) | (1 << 5), 2 << 29 | 1 << 19 | 8, 0xc4001000, 3, 2),
    rec(1000 << 3 | 4,
        5 << 22 | 0 << 11 | 1 << 15 | 1 << 17 | 0 << 18 | 8,
        1 << 31 | 1 << 16 | 1 << 7 | 4,
        (1 << 1) | (1 << 5), 2 << 29 | 1 << 19 | 8, 0xc4001000, 3, 4),
    rec(1000 << 3 | 5,
        5 << 22 | 0 << 11 | 1 << 15 | 1 << 17 | 0 << 18 | 8,
        1 << 31 | 1 << 16 | 1 << 7 | 4,
        (1 << 0) | (1 << 1) | (1 << 5),
        2 << 29 | 0 << 19 | 0, 0xc4001008, 3, 6),             # TERM
]
open(T + "/ctl.bin", "wb").write(b"".join(ctl) + bytes(32 * (256 - len(ctl))))

# The ring, deliberately WRAPPED: 520 records written into a 512 cap, so
# the live window is 8..519 and record k sits at k % 512.  Each one is
# an interrupt IN on device 5 endpoint 1 answered Chhltd|Nak in the
# start-split phase, with the microframe advancing, and hcdma carries
# the absolute index so a mis-ordered window is visible as a number.
ring = [b""] * 512
for k in range(520):
    ring[k % 512] = rec(
        (2000 + k) << 3 | (k & 7),
        5 << 22 | 1 << 11 | 1 << 15 | 1 << 17 | 3 << 18 | 5,
        1 << 31 | 1 << 7 | 4,
        (1 << 1) | (1 << 4),
        0 << 29 | 1 << 19 | 5, 0xd0000000 + k, 4, 2)
open(T + "/ring.bin", "wb").write(b"".join(ring))

# The WAIT array: two interesting periodic events, which is what gets
# kept when the mouse is actually moved.  First a complete-split that
# moved five bytes (Xfercomp|Chhltd|Ack, dma advanced, pktcnt down to
# 0), then a NYET.
wait = [
    rec(3000 << 3 | 1,
        5 << 22 | 1 << 11 | 1 << 15 | 1 << 17 | 3 << 18 | 5,
        1 << 31 | 1 << 16 | 1 << 7 | 4,
        (1 << 0) | (1 << 1) | (1 << 5),
        0 << 29 | 0 << 19 | 3, 0xc40407c5, 0, 3),
    rec(3001 << 3 | 2,
        5 << 22 | 1 << 11 | 1 << 15 | 1 << 17 | 3 << 18 | 5,
        1 << 31 | 1 << 16 | 1 << 7 | 4,
        (1 << 1) | (1 << 6),
        0 << 29 | 1 << 19 | 5, 0xc40407c0, 0, 3),
]
open(T + "/wait.bin", "wb").write(b"".join(wait) + bytes(32 * (64 - len(wait))))
open(T + "/wait0.bin", "wb").write(bytes(32 * 64))
PYEOF

#
# nring=520 nctl=4 lost=8, no endpoint filter, both arrays, no tail cap.
#
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "" 1 1 0 32 \
	"$T/wait.bin" 2 1 900 898 31 1 "0x1f4 0x1f0 0x7d0 0x3 0x1f4 0x7 0x1f4 0x0" 120 118 >"$T/out.txt" 2>"$T/err.txt"
rc=$?
if [ $rc -ne 0 ]; then
	echo "splittrace.sh: the decoder exited $rc" >&2
	cat "$T/err.txt" >&2
	exit 2
fi

fail=0
ck() {	# $1 what, $2 pattern that must appear
	if grep -q -- "$2" "$T/out.txt"; then
		echo "  ok   $1"
	else
		echo "  FAIL $1"
		echo "       expected to find: $2"
		fail=`expr $fail + 1`
	fi
}
nk() {	# $1 what, $2 pattern that must NOT appear
	if grep -q -- "$2" "$T/out.txt"; then
		echo "  FAIL $1"
		echo "       should not appear: $2"
		fail=`expr $fail + 1`
	else
		echo "  ok   $1"
	fi
}

echo "splittrace.sh: decoding four known control records and a wrapped ring"

# The control sequence, field by field.
ck "control: the device and endpoint are 5.0"		"ep5.0"
ck "control: a control endpoint decodes as ctl"		" ctl "
ck "control: direction in"				" in "
ck "control: frame 1000 microframe 2"			"frm 1000.2"
ck "control: one packet of eight bytes"			"pkt  1 xfer     8"
ck "control: DATA1"					"DATA1"
ck "control: the START-split phase prints lowercase ss"	" ss  "
ck "control: the COMPLETE-split phase prints CS"	" CS  "
ck "control: Chhltd|Ack decodes both bits"		"Chhltd|Ack"
ck "control: the final event has Xfercomp"		"Xfercomp|Chhltd|Ack"
ck "control: SS-ARM, SS-EV, PROMOTE and TERM all named" "PROMOTE"
ck "control: the terminal record is tagged TERM"	"TERM"
ck "control: dma advanced by the eight bytes"		"dma c4001008"
ck "control: the channel is 3"				"ch3 "

# The ring.
ck "ring: an interrupt endpoint decodes as intr"	" intr"
ck "ring: ep5.1 is the endpoint in the window"		"ep5.1"
ck "ring: Chhltd|Nak decodes as both bits"		"Chhltd|Nak"
ck "ring: the overwritten count is reported"		"8 overwritten"

#
# THE RING ARITHMETIC.  With 520 written into 512 the live window is
# records 8 through 519 and nothing older.  hcdma was loaded with the
# absolute index, so d0000008 must be the first body line and d0000000
# must be absent -- it was overwritten.  The sequence column must start
# at 8 and end at 519.
#
ck "ring: the oldest live record is index 8"		"d0000008"
nk "ring: index 0 was overwritten and is gone"		"d0000000 "
ck "ring: the newest record is index 519"		"d0000207"
ck "ring: sequence numbers are absolute, ending 519"	"   519 ch4"
ck "ring: and start at 8, not 0"			"     8 ch4"

# A record decoded with the wrong stride would still print; this is the
# check that the stride is right, because index k and sequence k agree
# only if every entry was unpacked at the right offset.
if python3 - "$T/out.txt" <<'PYEOF'
import re, sys
bad = 0
n = 0
for ln in open(sys.argv[1]):
    m = re.search(r"^\s+(\d+) ch4 .* dma d0000([0-9a-f]{3})", ln)
    if m:
        n += 1
        if int(m.group(1)) != int(m.group(2), 16):
            print("   seq %s != dma index %s" % (m.group(1), m.group(2)))
            bad += 1
print("   checked %d ring lines for seq==index" % n)
sys.exit(1 if bad or n != 512 else 0)
PYEOF
then
	echo "  ok   ring: every one of 512 entries decoded at the right offset"
else
	echo "  FAIL ring: seq and the embedded index disagree, or not 512 lines"
	fail=`expr $fail + 1`
fi

# Endpoint filtering: ask for 5.1 and the control array's 5.0 must go.
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "5.1" 1 1 0 32 \
	"$T/wait.bin" 2 1 900 898 31 1 "0x1f4 0x1f0 0x7d0 0x3 0x1f4 0x7 0x1f4 0x0" 120 118 >"$T/out2.txt" 2>&1
if grep -q "nothing for ep5.1" "$T/out2.txt" &&
   ! grep -q "^   .*ep5.0" "$T/out2.txt"; then
	echo "  ok   filter: -e 5.1 drops ep5.0 and says so for the control"
else
	echo "  FAIL filter: -e 5.1 did not behave"
	fail=`expr $fail + 1`
fi

# An all-zero pair must say so rather than printing 512 blank records.
python3 - "$T" <<'PYEOF'
import sys
T = sys.argv[1]
open(T + "/zero.bin", "wb").write(bytes(32 * 512))
PYEOF
python3 "$T/dec.py" "$T/zero.bin" "$T/zero.bin" 0 0 0 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 0 0 0 0 "" 0 0 >"$T/out3.txt" 2>&1
if grep -q "NOTHING WAS RECORDED" "$T/out3.txt"; then
	echo "  ok   empty: an unrecorded trace says so"
else
	echo "  FAIL empty: a zero trace did not announce itself"
	fail=`expr $fail + 1`
fi

# And the case that matters for the control: ring busy, control empty.
python3 "$T/dec.py" "$T/ring.bin" "$T/zero.bin" 520 0 8 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 0 0 0 0 "" 0 0 >"$T/out4.txt" 2>&1
if grep -q "CONTROL array is empty while the ring is not" "$T/out4.txt"; then
	echo "  ok   no control: an empty control array is called out"
else
	echo "  FAIL no control: an empty control array passed in silence"
	fail=`expr $fail + 1`
fi

#
# THE WAIT ARRAY AND ITS VERDICTS.  These are the only lines in the tool
# that draw a conclusion rather than printing a field, so they are the
# ones that can mislead.  Both branches are exercised: a non-empty wait
# must NOT be reported as an idle mouse, and an empty one with polls on
# the clock must NOT be reported as a broken split path.
#
ck "wait: the data record's five bytes show as dma advanced"	"dma c40407c5"
ck "wait: a NYET on a periodic endpoint is kept"		"Chhltd|Nyet"
ck "wait: the periodic denominators are printed"	"900 start-splits armed; complete-splits answered NAK 898, NYET 31, DATA 1"
ck "wait: a nonzero DATA says the path delivers reports"	"the split path DOES deliver reports"
#
# THE SIX SPLIT COUNTERS, and the two verdicts drawn from them -- the
# only lines in this part of the tool that say more than the numbers
# do, so the ones that can mislead.
#
ck "counters: the six are decoded in declaration order"	"splits completed 500, of them moving bytes 496 (2000 bytes), MOVING NOTHING 3"
ck "counters: promoted and terminal are printed"	"promoted to complete-split 500, taken as terminal 7"
ck "counters: a nonzero moving-nothing is called out"	"signature of a split that was"
#
# THE CHAIN PAST THE CONTROLLER.  Three states and they must not be
# confused: nothing queued, queued-but-unread, and queued-and-read.
#
ck "chain: queued and read are both printed"	"pointer events QUEUED 120, taken off by a reader 118"
ck "chain: queued+read with data reads as the chain carrying events"	"The chain from the device to a consumer HAS"
ck "chain: and says the counts need not match"	"back the CURRENT position"
ck "counters: the packet programming is printed"	"programmed ONE packet 500, more than one 0"
ck "wait: a non-empty wait says the path can now be judged"	"NON-EMPTY"
nk "wait: and does NOT call a non-empty wait an idle mouse"	"WHAT AN IDLE MOUSE LOOKS LIKE"

# The empty-wait branch, from out3 (nothing at all) and a third run with
# polls but no interesting event -- the state the board is actually in.
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 4196 4195 32 0 "0x1064 0x1060 0x4e20 0x0 0x1064 0x9 0x1064 0x0" 0 0 >"$T/out5.txt" 2>&1
if grep -q "WHAT AN IDLE MOUSE LOOKS LIKE" "$T/out5.txt" &&
   grep -q "NEEDS THE MOUSE MOVED" "$T/out5.txt" &&
   grep -q "has never moved a byte" "$T/out5.txt" &&
   ! grep -q "NO PERIODIC SPLIT HAS BEEN ARMED" "$T/out5.txt"; then
	echo "  ok   wait: empty with 4196 polls reads as an IDLE mouse, and"
	echo "       says the experiment needs the mouse moved"
else
	echo "  FAIL wait: an empty wait with polls on the clock did not say"
	echo "       that it is an idle mouse rather than a broken path --"
	echo "       which is the exact misreading this array exists to stop"
	fail=`expr $fail + 1`
fi
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 100 99 1 0 "0x64 0x0 0x0 0x64 0x0 0x64 0x0 0x64" 55 0 \
	>"$T/out7.txt" 2>&1
if grep -q "QUEUED 55 but NOTHING READ THEM" "$T/out7.txt" &&
   grep -q "NOT ONE split was programmed for a single" "$T/out7.txt" &&
   grep -q "two-phase handshake is not" "$T/out7.txt" &&
   grep -q "MOVING NOTHING 100" "$T/out7.txt"; then
	echo "  ok   counters: nothing promoted, no one-packet split, AND"
	echo "       events queued with no reader are all called out"
else
	echo "  FAIL counters: 100 completions with 0 promotions passed in"
	echo "       silence -- which is a split path running one-phase"
	fail=`expr $fail + 1`
fi
# and six words are required: five must refuse rather than mis-decode
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 100 99 1 0 "0x1 0x2 0x3 0x4 0x5 0x6 0x7" 0 0 \
	>"$T/out8.txt" 2>&1
if grep -q "read back 7 word(s), not 8" "$T/out8.txt"; then
	echo "  ok   counters: a short read refuses instead of decoding"
else
	echo "  FAIL counters: seven words were decoded as eight"
	fail=`expr $fail + 1`
fi
# the kernel must assert the struct size the reader assumes
if grep -q 'sizeof(Splitstat) == 32' "$ROOT/os/inferno/raspi3b/usbdwc.c"; then
	echo "  ok   kernel: usbdwc.c asserts the 24-byte Splitstat"
else
	echo "  FAIL kernel: usbdwc.c does not assert sizeof(Splitstat) == 32,"
	echo "       so a field could be added and the six counters above"
	echo "       would each be decoded as the next one"
	fail=`expr $fail + 1`
fi
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 4196 4195 32 0 \
	"0x1064 0x1060 0x4e20 0x0 0x1064 0x9 0x1064 0x0" 1 1 \
	>"$T/out9.txt" 2>&1
if grep -q "BUT THE CONTROLLER MOVED NO BYTES" "$T/out9.txt" &&
   ! grep -q "chain from the device to a consumer HAS" "$T/out9.txt"; then
	echo "  ok   chain: events with no controller data are NOT reported"
	echo "       as the whole chain working"
else
	echo "  FAIL chain: 1 queued and 1 read with DATA 0 was reported as"
	echo "       the whole chain working -- which is the exact reading"
	echo "       the board produced and it was about a boot-time event"
	fail=`expr $fail + 1`
fi
python3 "$T/dec.py" "$T/ring.bin" "$T/ctl.bin" 520 4 8 "" 1 1 0 32 \
	"$T/wait0.bin" 0 1 4196 4195 32 213 \
	"0x1064 0x1060 0x4e20 0x0 0x1064 0x9 0x1064 0x0" 204 1 \
	>"$T/out10.txt" 2>&1
if grep -q "THE USB PATH WORKS END TO END and nothing" "$T/out10.txt" &&
   ! grep -q "chain from the device to a consumer HAS" "$T/out10.txt"; then
	echo "  ok   chain: 204 queued / 1 read / 213 data reads as NOTHING"
	echo "       CONSUMING, not as a working consumer -- the board's own"
	echo "       numbers, which the first version got wrong"
else
	echo "  FAIL chain: 204 queued with 1 read was reported as a"
	echo "       consumer.  That 1 is a boot-time read and the 204 mouse"
	echo "       events were never taken off."
	fail=`expr $fail + 1`
fi
if grep -q "QUEUED 0 -- nothing has written a decoded" "$T/out3.txt"; then
	echo "  ok   chain: zero queued is distinguished from unread"
else
	echo "  FAIL chain: zero events queued was not called out"
	fail=`expr $fail + 1`
fi
if grep -q "NO PERIODIC SPLIT HAS BEEN ARMED" "$T/out3.txt"; then
	echo "  ok   wait: zero polls is reported as no endpoint, not as idle"
else
	echo "  FAIL wait: zero periodic polls was not distinguished from an"
	echo "       idle endpoint"
	fail=`expr $fail + 1`
fi

# The record size must be asserted in the kernel, or this whole test is
# checking a format nothing holds the kernel to.
if grep -q 'sizeof(Splitev) == 32' "$ROOT/os/inferno/raspi3b/usbdwc.c"; then
	echo "  ok   kernel: usbdwc.c asserts the 32-byte record"
else
	echo "  FAIL kernel: usbdwc.c does not assert sizeof(Splitev) == 32,"
	echo "       so a field could be added and every decode above would"
	echo "       silently be off by the padding"
	fail=`expr $fail + 1`
fi

if [ $fail -ne 0 ]; then
	echo "splittrace.sh: $fail check(s) FAILED"
	exit 2
fi
echo "splittrace.sh: all checks passed"
exit 0
