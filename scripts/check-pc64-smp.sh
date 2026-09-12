#!/bin/sh
# Boot pc64 on a two-processor machine and look for the ilockdepth fault.
#
# This is the reproducer for what was, for the length of this hunt,
# believed to be a Compute Engine phenomenon: ipc64dev panicking with
# "ilockdepth -1" on a rented instance perhaps half the time and never
# on this laptop.  It is not about the cloud.  A GCE e2-micro has two
# vCPUs and every local boot script here runs QEMU with one, so the
# kernel started a second processor there and never here.  Under
# "-smp 2" it reproduces locally in well under a minute.
#
# The control matters as much as the test: the same two-processor QEMU
# machine with "*ncpu=1" in plan9.ini, so the kernel leaves the second
# processor alone, boots clean.  Same hardware, same kernel, same ISO
# recipe -- the only difference is whether the AP is started.  Without
# that arm a failure here could be blamed on the extra vCPU rather than
# on the kernel's use of it.
#
# usage: scripts/check-pc64-smp.sh [runs]
# needs: a built os/inferno/pc64/ipc64dev and .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
RUNS=${1:-6}
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/pc64/ipc64dev
[ -f "$KERN" ] || { echo "check-pc64-smp: no $KERN; mk CONF=pc64dev first" >&2; exit 1; }

WORK=`mktemp -d`
# status latched and restored; every cleanup command made to
# succeed, because "set -e" would otherwise abort the trap and
# lose it.  See the fuller note in check-pc64-tcp.sh.
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/smp.iso" >/dev/null 2>&1
INFERNO_KERNEL=$KERN INFERNO_INI='*ncpu=1' \
	sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/one.iso" >/dev/null 2>&1

bad=0
one=0
i=1
while [ $i -le $RUNS ]; do
	sh "$ROOT/scripts/qemu-inferno-efi.sh" "$WORK/smp.iso" "$WORK/smp$i.log" 45 -smp 2 >/dev/null 2>&1
	if grep -q 'ilockdepth -\|ilockdepth [0-9]\|panic:' "$WORK/smp$i.log"; then
		bad=`expr $bad + 1`
	fi
	sh "$ROOT/scripts/qemu-inferno-efi.sh" "$WORK/one.iso" "$WORK/one$i.log" 45 -smp 2 >/dev/null 2>&1
	if grep -q 'ilockdepth -\|ilockdepth [0-9]\|panic:' "$WORK/one$i.log"; then
		one=`expr $one + 1`
	fi
	i=`expr $i + 1`
done

echo "-smp 2, AP started:     $bad of $RUNS runs faulted"
echo "-smp 2, *ncpu=1:        $one of $RUNS runs faulted"
if [ $one -gt 0 ]; then
	echo "check-pc64-smp: FAIL -- the uniprocessor control faulted too;"
	echo "  the fault is then not about starting the second processor." >&2
	exit 1
fi
if [ $bad -eq 0 ]; then
	echo "check-pc64-smp: no fault seen in $RUNS two-processor runs."
	echo "  It is intermittent -- roughly half of runs at the time this"
	echo "  was written -- so a clean sweep is weak evidence, not a pass."
	exit 0
fi
echo "check-pc64-smp: reproduced (this is the open bug, not a regression)"
exit 0
