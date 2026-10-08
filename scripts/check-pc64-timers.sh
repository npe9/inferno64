#!/bin/sh
# Boot pc64 with and without an HPET and require both to reach a shell.
#
# The second configuration is the one that matters.  archacpi.c makes
# arch->clockinit hpetinit when ACPI describes an HPET and i8253init
# when it does not, and for a long time only the first of those set the
# processor's frequency: i8253init programmed the counters and never
# called guesscpuhz(), so on a machine with no HPET m->cpuhz stayed
# zero, and the kernel died in lapictimerinit()'s assert(v >= (100*HZ))
# three subsystems away from the cause.
#
# QEMU always describes an HPET, so every local boot took the working
# path and the bug was found on a Google Compute Engine instance, which
# has no HPET.  "-machine q35,hpet=off" is that machine's shape, and it
# is why this check exists: the failure cost a rented machine to find
# once and costs nothing to catch again.
#
# usage: scripts/check-pc64-timers.sh [iso]
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
SECS=${SECS:-90}

# The iso is built here from the kernel that is in the tree, the way
# every other check does it.  It used to default to a file left in
# .qemu by whoever ran mkinferno-efi-iso.sh last, and that file was
# eight days old while this check reported "ok" twice a day: a stale
# image passes a boot test perfectly well, and says nothing about the
# kernel that was just built.  Pass an iso as $1 to test some other
# one deliberately.
if [ -n "$1" ]; then
	ISO=$1
	test -f "$ISO" || { echo "no iso: $ISO" >&2; exit 1; }
else
	KERN=$ROOT/os/inferno/pc64/ipc64
	[ -f "$KERN" ] || { echo "check-pc64-timers: no $KERN; mk CONF=pc64 first" >&2; exit 1; }
	WORK=`mktemp -d`
	trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0
	ISO=$WORK/t.iso
	INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$ISO" >/dev/null 2>&1
fi

fail=0
for hpet in on off; do
	log=$ROOT/.qemu/check-pc64-hpet-$hpet.log
	rm -f "$log"
	cp "$ROOT/.qemu/edk2-vars.fd" "$ROOT/.qemu/edk2-vars-hpet-$hpet.fd"
	timeout "$SECS" qemu-system-x86_64 \
		-machine q35,hpet=$hpet -m 1024 \
		-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
		-drive if=pflash,format=raw,unit=1,file="$ROOT/.qemu/edk2-vars-hpet-$hpet.fd" \
		-cdrom "$ISO" \
		-netdev user,id=net0 -device virtio-net,netdev=net0 \
		-serial "file:$log" \
		-display none -no-reboot >/dev/null 2>&1 || true

	# Unanchored, and ".*cpu0:" rather than "^cpu0:": the console
	# interleaves writes without newlines, so the line that reports the
	# clock can arrive with something in front of it.  Anchored, mhz
	# came back empty and the test below then said "reached a shell but
	# cpu0 is unreportedMHz" -- a working kernel reported as broken,
	# which is the direction that costs a day.  Verified against a
	# synthetic interleaved line.  See scripts/check-arm64-smp.sh.
	mhz=`sed -e 's/\r$//' "$log" | sed -n 's/.*cpu0: \([0-9]*\)MHz.*/\1/p' | head -1`
	if sed -e 's/\r$//' "$log" | grep -q 'spawn sh -n /dis/init'; then
		if [ "$mhz" = 0 ] || [ -z "$mhz" ]; then
			echo "hpet=$hpet: FAIL reached a shell but cpu0 is ${mhz:-unreported}MHz"
			fail=1
		else
			echo "hpet=$hpet: ok, cpu0 ${mhz}MHz, reached a shell"
		fi
	else
		echo "hpet=$hpet: FAIL no shell; cpu0 ${mhz:-unreported}MHz; see $log"
		sed -e 's/\r$//' "$log" | grep -a panic | head -2
		fail=1
	fi
done
exit $fail
