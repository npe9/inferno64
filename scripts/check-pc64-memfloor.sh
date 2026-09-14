#!/bin/sh
# The smallest machine this kernel runs useful work on.
#
# doc/inferno-cloud-modern.ms item 10: "density is what cloud economics
# is made of".  The number is not one number.  There is a floor to reach
# a shell and a higher floor to run a command in it, and they are worth
# reporting separately, because a kernel that boots and then cannot run
# anything is not a machine you can rent.
#
# Both arms are the SAME QEMU machine.  That is not a detail: the first
# version of this measurement booted the two arms on different hardware
# without noticing -- one passed -netdev/-device virtio-net and the
# other let QEMU attach its default e1000e -- and the e1000e arm stalled
# after link-up at 68M where the virtio arm ran on.  Two floors measured
# on two machines are not two floors.  Everything below is one machine,
# the same one scripts/qemu-inferno-efi.sh builds.
#
# The kernel's root is compiled in, so the floor mostly reflects the
# image: this kernel is about 9 MB and reserves memory up to MemMin,
# which the boot log prints.  A smaller root moves the number.
#
# usage: scripts/check-pc64-memfloor.sh [lo] [hi]
# needs: a built os/inferno/pc64/ipc64 and .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
LO=${1:-56}
HI=${2:-128}
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-pc64-memfloor: no $KERN; mk CONF=pc64 first" >&2; exit 1; }

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/m.iso" >/dev/null 2>&1

# One machine definition, used by both arms.  A string rather than a
# shell function because "timeout" cannot call a function and
# type-at-console.py takes the qemu command as its trailing argv; both
# want the words.  Nothing in these paths contains a space.
QBASE="-machine q35 -display none -no-reboot"
QDISK="-drive if=pflash,format=raw,unit=0,readonly=on,file=$ROOT/.qemu/edk2-code.fd"
QNET="-netdev user,id=net0 -device virtio-net,netdev=net0"

boots() {	# boots MiB -> 0 if it reaches the end of the bind list
	cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"
	rm -f "$WORK/b.log"
	timeout 90 qemu-system-x86_64 $QBASE -m "$1" $QDISK \
		-drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
		-cdrom "$WORK/m.iso" $QNET \
		-serial "file:$WORK/b.log" >/dev/null 2>&1 || true
	grep -q 'bound #S' "$WORK/b.log"
}

works() {	# works MiB -> 0 if a typed command runs and answers
	cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"
	rm -f "$WORK/w.in" "$WORK/w.out" "$WORK/w.log"
	# Waits for the guest to say it is ready rather than guessing: a
	# smaller machine boots slower, and a fixed delay measures the
	# delay.  150s is a ceiling, not a plan.
	INFERNO_CONSOLE_WAITFOR='bound #S' INFERNO_CONSOLE_HOLD=30 \
	timeout 260 python3 "$ROOT/scripts/type-at-console.py" "$WORK/w" 150 \
		'ls /dis | wc; echo WORK-OK' \
		qemu-system-x86_64 $QBASE -m "$1" $QDISK \
		-drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
		-cdrom "$WORK/m.iso" $QNET \
		-chardev pipe,id=c0,path="$WORK/w" -serial chardev:c0 \
		>"$WORK/w.log" 2>"$WORK/w.err" || true
	grep -q WORK-OK "$WORK/w.log"
}

# Bisect rather than sweep: the property is monotone in memory, and a
# bisect over 56..128 is seven boots instead of seventy.
bisect() {	# bisect predicate lo hi -> smallest MiB satisfying it
	p=$1; lo=$2; hi=$3
	if ! $p $hi; then echo ""; return; fi
	while [ `expr $hi - $lo` -gt 1 ]; do
		mid=`expr \( $lo + $hi \) / 2`
		if $p $mid; then hi=$mid; else lo=$mid; fi
	done
	echo $hi
}

echo "kernel `ls -l \"$KERN\" | awk '{print $5}'` bytes; searching $LO..$HI MiB"
BF=`bisect boots $LO $HI`
[ -n "$BF" ] || { echo "check-pc64-memfloor: does not boot even at $HI MiB" >&2; exit 1; }
echo "boot to a shell:      $BF MiB"
WF=`bisect works $LO $HI`
[ -n "$WF" ] || { echo "check-pc64-memfloor: cannot run a command even at $HI MiB" >&2; exit 1; }
echo "run a command:        $WF MiB"
echo "MemMin the kernel reports: `grep -o 'MemMin 0x[0-9a-f]*' \"$WORK/b.log\" | head -1`"
