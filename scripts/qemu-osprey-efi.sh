#!/bin/sh
# Boot the Osprey EFI ISO under QEMU with the serial console captured.
# usage: scripts/qemu-osprey-efi.sh [iso] [logfile] [seconds]
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
ISO=${1:-$ROOT/.qemu/osprey-efi.iso}
LOG=${2:-$ROOT/.qemu/serial.log}
SECS=${3:-40}

rm -f "$LOG"
cp "$ROOT/.qemu/edk2-vars.fd" "$ROOT/.qemu/edk2-vars-run.fd"
timeout "$SECS" qemu-system-x86_64 \
	-machine q35 -m 1024 \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$ROOT/.qemu/edk2-vars-run.fd" \
	-cdrom "$ISO" \
	-serial "file:$LOG" \
	-display none -no-reboot >/dev/null 2>&1 || true
sed -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' -e 's/\r$//' "$LOG"
