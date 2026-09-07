#!/bin/sh
# Boot the Inferno UEFI ISO under QEMU with the serial console captured.
# The firmware is edk2 (OVMF), which is the same class of firmware a
# cloud machine runs; there is no CSM in this path.
# usage: scripts/qemu-inferno-efi.sh [iso] [logfile] [seconds] [extra qemu args...]
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
ISO=${1:-$ROOT/.qemu/inferno-efi.iso}
LOG=${2:-$ROOT/.qemu/inferno-efi-serial.log}
SECS=${3:-90}
[ $# -gt 0 ] && shift
[ $# -gt 0 ] && shift
[ $# -gt 0 ] && shift

rm -f "$LOG"
cp "$ROOT/.qemu/edk2-vars.fd" "$ROOT/.qemu/edk2-vars-run.fd"
timeout "$SECS" qemu-system-x86_64 \
	-machine q35 -m 1024 \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$ROOT/.qemu/edk2-vars-run.fd" \
	-cdrom "$ISO" \
	-netdev user,id=net0 -device virtio-net,netdev=net0 \
	-serial "file:$LOG" \
	-display none -no-reboot "$@" >/dev/null 2>&1 || true
sed -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' -e 's/\r$//' "$LOG"
