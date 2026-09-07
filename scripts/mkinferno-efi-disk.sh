#!/bin/sh
# Build a raw GPT disk image holding the Inferno pc64 kernel on an EFI
# system partition.
#
# This is the shape the providers that take a custom operating system
# want, and none of them take the ISO scripts/mkinferno-efi-iso.sh
# builds: AWS wants a raw disk written to S3, imported as an EBS
# snapshot and registered as an AMI; Compute Engine wants the same raw
# disk named disk.raw inside a tar.gz; OCI's Bring Your Own Image takes
# it too; and a rented metal box in rescue mode boots it after dd to
# the disk.
#
# usage: scripts/mkinferno-efi-disk.sh [disk.raw] [size-in-MiB]
#
# INFERNO_KERNEL   kernel to install as /amd64/ipc64
# INFERNO_INI      extra plan9.ini lines, newline separated

set -e

ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

DISK=${1:-$ROOT/.qemu/inferno-efi.raw}
MIB=${2:-128}
KERNEL=${INFERNO_KERNEL:-$ROOT/Inferno/amd64/ipc64}
LOADER=$ROOT/os/inferno/boot/efi/bootx64.efi
TREE=`mktemp -d "${TMPDIR:-/tmp}/inferno-disk.XXXXXX"`
ESP=$TREE/esp.fat

trap 'rm -rf "$TREE"' 0

echo "mk bootx64.efi"
(cd "$ROOT/os/inferno/boot/efi" && mk bootx64.efi)

test -f "$KERNEL" || { echo "no kernel: $KERNEL" >&2; exit 1; }

CFG=$TREE/plan9.ini
# console=0 is not optional; see scripts/mkinferno-efi-iso.sh.
cat >"$CFG" <<INI
bootfile=/amd64/ipc64
console=0
INI
if [ -n "$INFERNO_INI" ]; then
	printf '%s\n' "$INFERNO_INI" >>"$CFG"
fi
printf 'fs0:\\EFI\\BOOT\\BOOTX64.EFI\n' >"$TREE/startup.nsh"

# The ESP is one megabyte short of the partition so the FAT and the
# partition entry agree; mformat sizes from the file it is given.
ESPMIB=`expr $MIB - 2`
dd if=/dev/zero of="$ESP" bs=1048576 count=$ESPMIB 2>/dev/null
mformat -i "$ESP" -F -v INFERNO ::
mmd -i "$ESP" ::/EFI ::/EFI/BOOT ::/amd64 ::/cfg
mcopy -i "$ESP" "$LOADER" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP" "$KERNEL" ::/amd64/ipc64
mcopy -i "$ESP" "$CFG" ::/cfg/plan9.ini
mcopy -i "$ESP" "$CFG" ::/plan9.ini
mcopy -i "$ESP" "$TREE/startup.nsh" ::/startup.nsh

mkdir -p `dirname "$DISK"`
rm -f "$DISK"
python3 "$ROOT/scripts/mkgptdisk.py" "$DISK" "$ESP" "$MIB"
ls -l "$DISK"

# Compute Engine takes the image as a file named exactly disk.raw, alone
# in a gzipped tar written in the old GNU tar format, and the raw file
# must be a whole number of gigabytes.  INFERNO_GCE_TAR names the
# archive to write; the disk image is left in place either way.
#
# Built to that documented requirement and not past it: the archive has
# not been through Compute Engine's importer here, only the disk inside
# it has been booted under OVMF.  GNU tar spells the format oldgnu and
# the bsdtar on a Mac spells it gnutar, hence the probe.
if [ -n "$INFERNO_GCE_TAR" ]; then
	if [ `expr $MIB % 1024` -ne 0 ]; then
		echo "gce: image is $MIB MiB; Compute Engine wants a whole" \
		     "number of GiB, so pass 1024 or a multiple" >&2
		exit 1
	fi
	TARFMT=--format=oldgnu
	if ! tar $TARFMT -cf /dev/null -T /dev/null 2>/dev/null; then
		TARFMT=--format=gnutar
		tar $TARFMT -cf /dev/null -T /dev/null 2>/dev/null || TARFMT=
	fi
	D=`dirname "$DISK"`
	B=`basename "$DISK"`
	if [ "$B" != disk.raw ]; then
		ln -f "$DISK" "$D/disk.raw" 2>/dev/null || cp "$DISK" "$D/disk.raw"
	fi
	tar -C "$D" $TARFMT -czf "$INFERNO_GCE_TAR" disk.raw
	[ "$B" != disk.raw ] && rm -f "$D/disk.raw"
	echo "gce: $INFERNO_GCE_TAR ($TARFMT)"
	ls -l "$INFERNO_GCE_TAR"
fi
