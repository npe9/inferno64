#!/usr/bin/env bash
#
# qemu9front.sh -- boot the ISO scripts/mkiso9front.sh builds and run
# commands on it.
#
# The console is the serial line: cfg/plan9.ini says console=0, so
# everything the loader, the kernel and rc print comes out of COM1 and
# everything typed goes in.  Two prompts have to be answered before
# there is a shell -- bootrc's bootargs, whose default is already the
# CD, and factotum's user -- and both take an empty line.
#
# Characters are fed a line at a time with a pause between: the
# console takes a whole line at once and drops the first character of
# whatever arrives while it is still handling the last one, which
# looks exactly like a program that does not exist.
#
# -bios boots the El Torito image with the machine's own firmware
# (386/9bootiso) rather than through EFI.  Otherwise the edk2 build in
# .qemu is used and 386/efiboot.fat is what the firmware loads.
#
# Usage: scripts/qemu9front.sh [-bios] [-i iso] [-l log] [command...]
# With no commands it boots to the shell prompt and stops there.

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD

bios=0
ISO=$ROOT/.qemu/9front.amd64.iso
LOG=$ROOT/.qemu/9front-iso.log
while [ $# -gt 0 ]; do
	case "$1" in
	-bios)	bios=1; shift;;
	-i)	ISO=$2; shift 2;;
	-l)	LOG=$2; shift 2;;
	*)	break;;
	esac
done

[ -f "$ISO" ] || { echo "qemu9front: no $ISO; run scripts/mkiso9front.sh" >&2; exit 1; }

fw=()
if [ "$bios" = 0 ]; then
	cp "$ROOT/.qemu/edk2-vars.fd" "$ROOT/.qemu/edk2-vars-run.fd"
	fw=(-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd"
	    -drive if=pflash,format=raw,unit=1,file="$ROOT/.qemu/edk2-vars-run.fd")
fi

# 25 seconds to the bootargs prompt, another 12 to the user prompt:
# generous, and the pauses cost nothing but wall clock.
feed() {
	sleep 25; printf '\n'		# bootargs: take the default, the CD
	sleep 12; printf '\n'		# user: glenda
	sleep 12
	for c in "$@"; do
		printf ' %s\n' "$c"
		sleep 3
	done
	sleep 5
}

secs=$((60 + 3 * $# + 15))
feed "$@" | timeout "$secs" qemu-system-x86_64 \
	-machine q35 -m 1024 \
	"${fw[@]}" \
	-cdrom "$ISO" \
	-serial stdio -display none -no-reboot 2>&1 \
	| sed -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' -e 's/\r$//' > "$LOG" || true

cat "$LOG"
