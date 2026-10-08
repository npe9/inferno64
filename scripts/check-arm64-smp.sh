#!/bin/sh
# virtarm64 starts its secondary processors, and clips at MAXMACH.
#
# This exists because the obvious way to run it gives the wrong answer
# silently.  Booted with "-kernel", virtarm64 reaches a shell on any
# -smp and starts NO secondaries, and says so only as
#
#	ARM64-ACPI-NONE no loader configuration
#
# because startcpus() enumerates processors from the ACPI MADT and
# "-kernel" hands the kernel no ACPI at all.  A run that way looks
# exactly like an SMP regression -- it looked like one here, after a
# merge that had touched the shared port code, which is the worst
# possible moment to be misled.
#
# So this boots the UEFI disk, where the firmware provides ACPI.
#
# usage: scripts/check-arm64-smp.sh
# needs: os/inferno/virtarm64/ivirtarm64 and .qemu/edk2-aarch64-code.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/virtarm64/ivirtarm64
[ -f "$KERN" ] || { echo "check-arm64-smp: no $KERN; mk ivirtarm64 first" >&2; exit 1; }
FW=$ROOT/.qemu/edk2-aarch64-code.fd
[ -f "$FW" ] || { echo "check-arm64-smp: no $FW" >&2; exit 1; }

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-disk-arm64.sh" \
	"$WORK/a.img" >/dev/null 2>&1

run() {	# run ncpu mem logfile
	dd if=/dev/zero of="$WORK/vars.fd" bs=1m count=64 2>/dev/null
	timeout 120 qemu-system-aarch64 -M virt -cpu cortex-a72 \
		-smp "$1" -m "$2" -display none -no-reboot \
		-drive if=pflash,format=raw,readonly=on,file="$FW" \
		-drive if=pflash,format=raw,file="$WORK/vars.fd" \
		-drive if=none,id=hd,format=raw,file="$WORK/a.img" \
		-device virtio-blk-device,drive=hd \
		-serial "file:$3" >/dev/null 2>&1 || true
}

# A success marker read out of a kernel console log must NOT be anchored
# with ^.  The console interleaves writes from several processors without
# newlines -- on -smp 17 especially -- so a line that is printed can
# arrive with something else in front of it, and an anchored grep then
# reports the thing as absent.  Every check below whose absence means
# FAIL is therefore unanchored; the markers are distinctive enough that a
# false match is not a concern.
#
# This cost the raspi3b-port session a real one: tests/efs-crash.sh lost
# an interleaved "MARK done" and counted the trial as a filesystem fault,
# manufacturing fault reports in the one place a comment forbids it.
# Three of the six checks in this file were already unanchored, which is
# the tell that the other three were an oversight rather than a decision.

ok=1

run 4 512 "$WORK/four.log"
if ! grep -q 'cpu: 3 started, 3 answered' "$WORK/four.log"; then
	echo "check-arm64-smp: FAIL -- 3 secondaries did not start on -smp 4" >&2
	grep -E '^cpu: |ACPI' "$WORK/four.log" >&2 || true
	ok=0
fi
grep -q 'cpu: machnos 1 2 3' "$WORK/four.log" || {
	echo "check-arm64-smp: FAIL -- secondaries did not take their own machnos" >&2; ok=0; }
grep -q 'interactive sh' "$WORK/four.log" || {
	echo "check-arm64-smp: FAIL -- no shell on -smp 4" >&2; ok=0; }

# More processors than MAXMACH: the extra ones must be left alone rather
# than overrunning machp[].
run 17 1024 "$WORK/seventeen.log"
grep -q 'more processors than MAXMACH' "$WORK/seventeen.log" || {
	echo "check-arm64-smp: FAIL -- no MAXMACH clip on -smp 17" >&2; ok=0; }
grep -q 'cpu: 7 started, 7 answered' "$WORK/seventeen.log" || {
	echo "check-arm64-smp: FAIL -- did not start MAXMACH-1 secondaries on -smp 17" >&2; ok=0; }
grep -q 'interactive sh' "$WORK/seventeen.log" || {
	echo "check-arm64-smp: FAIL -- no shell on -smp 17" >&2; ok=0; }

for f in "$WORK/four.log" "$WORK/seventeen.log"; do
	if grep -q 'panic' "$f"; then
		echo "check-arm64-smp: FAIL -- panic in `basename $f`" >&2
		grep -m2 'panic' "$f" >&2
		ok=0
	fi
done

[ $ok = 1 ] || exit 1
echo "check-arm64-smp: ok"
sed -n 's/^\(cpu: .*\)$/  \1/p' "$WORK/four.log"
sed -n 's/^\(cpu: .*MAXMACH.*\)$/  \1/p' "$WORK/seventeen.log"
sed -n 's/^\(cpu: ticks.*\)$/  \1/p' "$WORK/seventeen.log"
