#!/bin/sh
# Does this log come from this kernel?
#
#	scripts/check-kernel-stamp.sh <log> <kernel>
#
# WHY.  An address means nothing without the image it came from.  This
# branch resolved a malloctag against the tree's current kernel rather
# than the one that had run and got a confident "execatidle+0x65" for an
# address the right binary calls "newprog+0x72" -- two plausible
# functions, no warning, and a wrong conclusion that stood until the
# binaries were compared.
#
# kerndate is printed in the boot banner AND, since this check existed,
# on the soak line every 120 seconds, because Compute Engine's serial
# API returns the last mebibyte and on any run long enough to measure
# the banner has scrolled out.  A check that can only read the banner
# would not run on the path that needs it.
#
# Exit 0 match, 1 mismatch, 2 cannot tell.  2 is not a pass: a stamp
# that is absent from the log is the case where a silent ok does the
# damage, which is the whole shape of bug this tree has been auditing.
set -u
[ $# -eq 2 ] || { echo "usage: check-kernel-stamp.sh <log> <kernel>" >&2; exit 2; }
log=$1; kern=$2
[ -f "$log" ]  || { echo "check-kernel-stamp: no log $log" >&2; exit 2; }
[ -f "$kern" ] || { echo "check-kernel-stamp: no kernel $kern" >&2; exit 2; }

# Unanchored on purpose: the console interleaves writes from several
# processors without newlines, so a marker that really was printed can
# arrive with something in front of it.  See scripts/check-arm64-smp.sh.
st=`grep -ao 'kernel built at [0-9]*' "$log" | tail -1 | tr -dc 0-9`
[ -n "$st" ] || st=`grep -ao 'Inferno release built at [0-9]*' "$log" | tail -1 | tr -dc 0-9`
[ -n "$st" ] || {
	echo "check-kernel-stamp: no build stamp in $log -- CANNOT TELL" >&2
	echo "check-kernel-stamp: (a truncated serial tail with no soak line does this)" >&2
	exit 2; }

python3 - "$st" "$kern" <<'PY'
import sys
st = int(sys.argv[1]); kern = sys.argv[2]
d = open(kern, 'rb').read()
if d.find(st.to_bytes(4, 'little')) >= 0:
    print("check-kernel-stamp: ok -- log stamp %d is in %s" % (st, kern))
    sys.exit(0)
print("check-kernel-stamp: FAIL -- log says built at %d, not found in %s" % (st, kern),
      file=sys.stderr)
print("check-kernel-stamp: do not resolve addresses from this log against this binary",
      file=sys.stderr)
sys.exit(1)
PY
