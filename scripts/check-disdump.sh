#!/bin/sh
# The multicore instrumentation is silent unless *disdump=1 asks for it.
#
# port/dis.c carries a dump of every process, every run queue and every
# VM waiter, and port/portclock.c called it forty seconds into every
# boot.  On a laptop with a scrollback that is a debugging aid; on a
# rented instance the serial console is the whole interface, and a
# console that fills with kernel internals is the console someone is
# trying to read a DHCP lease off.  The dump and the "vmq: N
# interpreters blocked" line are behind a boot flag now.
#
# Two arms, because "no dump appeared" is also what a kernel that
# crashed before the fortieth second prints.  The *disdump=1 arm is the
# positive control: the same kernel, the same forty seconds, and the
# dump has to be there.  Both arms must reach a shell.
#
# The quiet arm looks for every prefix the instrumentation prints under,
# not just the dump's.  The first version of this check greped for
# disdump()'s own lines alone, and the multicore branch -- which this
# one will adopt -- calls stalldump() at 60 and 70 seconds and
# soakline() every 120 seconds from hzclock() with no flag on either.
# A check that only knows about disdump() passes a kernel that prints
# "soak:" down an instance's serial console for the life of the
# machine.  So the list below is the list, and a print added under a
# new prefix has to be added to it.
#
# What is deliberately NOT here: "the counts disagree", "waiter %d %s
# state", "vmachine: prog", and the poolcheckoverlap sweep.  Those
# report a fault rather than a measurement.  They must stay
# unconditional, they are silent unless something is wrong, and
# check-pc64-parallelvm greps for the first of them.
#
# usage: scripts/check-disdump.sh
# needs: os/inferno/pc64/ipc64, .qemu/edk2-code.fd, .qemu/edk2-vars.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
# Long enough for the guest to reach tick 70, not just tick 40.  The
# dump this check was written for is at 40*HZ, but the branch this one
# will adopt also prints at 60 and 70, and under OVMF and TCG a 90-second
# wall-clock window does not always get there -- so a quiet arm could
# have been quiet about a kernel that simply had not printed yet.  A
# boot of that kernel with 120 seconds showed 43 stall: lines, so 150
# leaves margin.
SECS=${SECS:-150}

KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-disdump: no $KERN; mk CONF=pc64 first" >&2; exit 1; }
for f in "$ROOT/.qemu/edk2-code.fd" "$ROOT/.qemu/edk2-vars.fd"; do
	[ -f "$f" ] || { echo "check-disdump: no $f" >&2; exit 1; }
done

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

fail=0
for arm in off on; do
	case $arm in
	off)	INI='';;
	on)	INI='*disdump=1';;
	esac
	INFERNO_KERNEL=$KERN INFERNO_INI="$INI" \
		sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/$arm.iso" >/dev/null 2>&1
	cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars-$arm.fd"
	log=$WORK/$arm.log
	# The prints are at 40, 60 and 120 ticks-seconds, so the boot has
	# to run well past forty seconds of GUEST time for either arm to
	# mean anything; SECS is wall clock and the two are not the same
	# under TCG.
	timeout "$SECS" qemu-system-x86_64 \
		-machine q35 -m 1024 \
		-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
		-drive if=pflash,format=raw,unit=1,file="$WORK/vars-$arm.fd" \
		-cdrom "$WORK/$arm.iso" \
		-netdev user,id=net0 -device virtio-net,netdev=net0 \
		-serial "file:$log" \
		-display none -no-reboot >/dev/null 2>&1 || true

	# every prefix the temporary instrumentation prints under
	NOISE='dis: parked for work|dis: global runq|kstack: least headroom'
	NOISE="$NOISE"'|^soak:|^stall:|^nvm:|^audit:|^runq: [0-9]+ dis programs'
	NOISE="$NOISE"'|^vmq: [0-9]+ interpreters'

	shell=no; dump=no
	sed -e 's/\r$//' "$log" | grep -q 'spawn sh -n /dis/init' && shell=yes
	sed -e 's/\r$//' "$log" | grep -qE "$NOISE" && dump=yes
	echo "*disdump=$arm: shell=$shell instrumentation=$dump"
	if [ $shell = no ]; then
		echo "check-disdump: FAIL -- the $arm arm never reached a shell" >&2
		sed -e 's/\r$//' "$log" | grep -a panic | head -2
		fail=1
		continue
	fi
	case "$arm:$dump" in
	off:yes)
		echo "check-disdump: FAIL -- instrumentation printed with no *disdump:" >&2
		sed -e 's/\r$//' "$log" | grep -aE "$NOISE" | sed 's/^/    | /' | head -4
		fail=1;;
	on:no)
		echo "check-disdump: FAIL -- *disdump=1 printed nothing" >&2
		fail=1;;
	esac
done

[ $fail -eq 0 ] || exit 1
echo "check-disdump: ok -- quiet by default, reports when asked"
