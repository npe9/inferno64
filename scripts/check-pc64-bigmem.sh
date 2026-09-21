#!/bin/sh
# pc64 boots on a machine with more memory than 4 GiB, and the pool
# overlap checker stays quiet on it.
#
# Every cloud machine worth renting has more than 4 GiB and no local test
# had any, which is how two faults got out to hardware.  A 16 GiB
# instance once recorded conf.npage for 17 GiB, asked the pool for a 3.4
# GiB contiguous chunk, was served it from above 4 GiB and page-faulted
# on the first write; and the pool overlap checker, whose comment said it
# had never fired, fires on a big machine with a chain head whose magic
# is wrong.  Neither is visible in a 1 GiB guest.
#
# "qemu -m 16384" is the reproduction for both, it costs one boot, and it
# is free where an instance is not.
#
# Two arms, because "it did not reach a shell" is also what a broken
# kernel does at any size: the 1 GiB boot is the control, and it has to
# reach a shell for the 16 GiB result to mean anything.
#
# *disdump=1 is passed because the overlap sweep is behind that flag on
# the branch this one is adopting, and ungated here -- one line that
# works either way.
#
# EXPECTED TO FAIL on this branch as it stands: pc64 page-faults at 16
# GiB, and the fix for it (a 32-bit chunk size, plus 2 MiB pages) is on
# the multicore branch.  It is here to notice the day that stops being
# true -- see doc/merge-parallelvm-cloud.ms.
#
# usage: scripts/check-pc64-bigmem.sh
# needs: os/inferno/pc64/ipc64, .qemu/edk2-code.fd, .qemu/edk2-vars.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
SECS=${SECS:-150}

KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-pc64-bigmem: no $KERN; mk CONF=pc64 first" >&2; exit 1; }
for f in "$ROOT/.qemu/edk2-code.fd" "$ROOT/.qemu/edk2-vars.fd"; do
	[ -f "$f" ] || { echo "check-pc64-bigmem: no $f" >&2; exit 1; }
done

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

INFERNO_KERNEL=$KERN INFERNO_INI='*disdump=1' \
	sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/b.iso" >/dev/null 2>&1

fail=0
for mb in 1024 16384; do
	cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars-$mb.fd"
	log=$WORK/$mb.log
	timeout "$SECS" qemu-system-x86_64 \
		-machine q35 -m $mb \
		-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
		-drive if=pflash,format=raw,unit=1,file="$WORK/vars-$mb.fd" \
		-cdrom "$WORK/b.iso" \
		-netdev user,id=net0 -device virtio-net,netdev=net0 \
		-serial "file:$log" \
		-display none -no-reboot >/dev/null 2>&1 || true

	shell=no; overlap=no; panic=
	sed -e 's/\r$//' "$log" | grep -q 'spawn sh -n /dis/init' && shell=yes
	sed -e 's/\r$//' "$log" | grep -q 'pooloverlap' && overlap=yes
	panic=`sed -e 's/\r$//' "$log" | grep -a '^panic:' | head -1`
	# how much of the machine the kernel decided it had
	pages=`sed -e 's/\r$//' "$log" | sed -n 's/^.*npage 0x[0-9a-f]* \([0-9]*\)$/\1/p' \
		| awk '{s+=$1} END {print s+0}'`
	printf '%6dM: shell=%-3s pooloverlap=%-3s pages=%s %s\n' \
		"$mb" "$shell" "$overlap" "$pages" "$panic"

	case "$mb:$shell" in
	1024:no)
		echo "check-pc64-bigmem: cannot tell -- the 1 GiB control did not reach a shell" >&2
		exit 1;;
	16384:no)
		echo "check-pc64-bigmem: FAIL -- 16 GiB did not reach a shell" >&2
		fail=1;;
	esac
	if [ "$mb" = 16384 ] && [ "$overlap" = yes ]; then
		echo "check-pc64-bigmem: FAIL -- the pool overlap checker fired:" >&2
		sed -e 's/\r$//' "$log" | grep -a 'pooloverlap' | sed 's/^/    | /' | head -4 >&2
		fail=1
	fi
done

[ $fail -eq 0 ] || exit 1
echo "check-pc64-bigmem: ok -- 16 GiB boots and the pools do not overlap"
