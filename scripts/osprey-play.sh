#!/bin/sh
# Boot the library-OS personality under QEMU with a display, to be used
# rather than checked.
#
# The difference from the harness (scripts/osprey-console.py) is only
# that this one is for a person: a Cocoa window instead of -display
# none, the serial console on a log rather than on stdout, and an image
# whose personality stays up for hours instead of the seconds a check
# needs.  Build that image with
#
#	OSPREY_NOBOOTPROMPT='local!/dev/sdE0/fs' \
#	OSPREY_KERNEL=$PWD/os/osprey/pc64/9p964 \
#	sh scripts/mkosprey-efi-iso.sh $PWD/.qemu/osprey-play.iso
#
# after setting p9inputloop's argument in os/osprey/cmd/p9/main.c to
# something long.  The committed source is 15 seconds, which is what the
# check wants and is no use to a person.
#
# No disk.  The checks open .qemu/9front-root.qcow2 read-write, and QEMU
# locks an image it has open: a machine left running with that disk
# attached makes every check that wants it fail to start, with an empty
# log and no reason - which is exactly what it did, twice, before this
# line was written.  The library-OS personality does not need the disk;
# what it reads comes from its own boot files and from the 9P server
# container beside it.
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
ISO="${1:-$ROOT/.qemu/osprey-play.iso}"
LOG="${2:-/tmp/osprey-play.log}"
# A QMP socket, so a screendump can be taken of a machine that is being
# used.  Unix socket paths are short on this system - a path much over a
# hundred characters is refused and QEMU exits with an empty log - so
# this one lives in /tmp rather than anywhere deeper.
QMP="${QMP:-/tmp/osprey-play.qmp}"
rm -f "$QMP"
cp "$ROOT/.qemu/edk2-vars.fd" "$ROOT/.qemu/edk2-vars-play.fd"
exec qemu-system-x86_64 -machine q35 -m 1024 -smp 2 \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$ROOT/.qemu/edk2-vars-play.fd" \
	-cdrom "$ISO" \
	-netdev user,id=n0 -device e1000,netdev=n0 \
	-monitor none -no-reboot \
	-qmp "unix:${QMP:-/tmp/osprey-play.qmp},server,nowait" \
	-serial "file:$LOG"
