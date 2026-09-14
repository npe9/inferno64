#!/bin/sh
# Build a FAT EFI system partition carrying the Inferno virtarm64 kernel
# and the AArch64 UEFI loader, as a raw disk image AAVMF will boot from
# its removable-media path (\EFI\BOOT\BOOTAA64.EFI).
#
# This is the arm64 half of scripts/mkinferno-efi-iso.sh.  It is a bare
# FAT image rather than an ISO because the AArch64 firmware in QEMU
# offers no El Torito path: the image goes on as -drive if=none plus a
# usb-storage or virtio-blk device and the firmware finds it as
# removable media.
#
# usage: scripts/mkinferno-efi-disk-arm64.sh [image] [size-in-MiB]
#
# INFERNO_KERNEL   kernel to install as /aarch64/ivirtarm64
# INFERNO_INI      extra plan9.ini lines, newline separated
# INFERNO_GCE_TAR  also write a Compute Engine image archive here
#
# With INFERNO_GCE_TAR set this emits a GPT disk with the FAT as its EFI
# system partition, the same shape scripts/mkinferno-efi-disk.sh builds
# for amd64, because that is what a provider imports.  Without it the
# output is the bare FAT image it has always been, so the QEMU boot tests
# that pass it as removable media are unaffected.  Checked by building
# with this script and with the previous one and comparing: 38 bytes
# differ, and the previous script compared against ITSELF across two
# runs differs in the same 38 -- the FAT volume serial at offset 40,
# which mformat takes from the clock, and directory-entry timestamps.
# The image has never been byte-reproducible; nothing here changed it.
# AAVMF
# finds \EFI\BOOT\BOOTAA64.EFI either way, but only one of the two is
# a disk a cloud will take.

set -e

ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

IMG=${1:-$ROOT/.qemu/inferno-efi-arm64.img}
# Only consulted when a GPT disk is being built; the bare-FAT path sizes
# itself from mformat's -T as before.
MIB=${2:-1024}
KERNEL=${INFERNO_KERNEL:-$ROOT/Inferno/aarch64/bin/ivirtarm64}
LOADER=$ROOT/os/inferno/boot/efi/bootaa64.efi
TREE=`mktemp -d "${TMPDIR:-/tmp}/inferno-arm64.XXXXXX"`

trap 'rm -rf "$TREE"' 0

echo "mk bootaa64.efi"
(cd "$ROOT/os/inferno/boot/efi" && mk bootaa64.efi)

test -f "$KERNEL" || { echo "no kernel: $KERNEL" >&2; exit 1; }

CFG=$TREE/plan9.ini
# console=0 for the same reason the amd64 recipe gives: this board links
# a PL011 console and a framebuffer one, and with no console= line a
# serial capture can come back empty, which looks exactly like a hang.
cat >"$CFG" <<INI
bootfile=/aarch64/ivirtarm64
console=0
INI
if [ -n "$INFERNO_INI" ]; then
	printf '%s\n' "$INFERNO_INI" >>"$CFG"
fi

echo "image $IMG"
mkdir -p `dirname "$IMG"`
rm -f "$IMG"
if [ -n "$INFERNO_GCE_TAR" ]; then
	# The ESP is two MiB short of the partition, as in the amd64
	# recipe: mformat sizes the FAT from the file it is given, and
	# the FAT and the partition entry have to agree.
	ESP=$TREE/esp.fat
	ESPMIB=`expr $MIB - 2`
	dd if=/dev/zero of="$ESP" bs=1048576 count=$ESPMIB 2>/dev/null
	mformat -i "$ESP" -F -v INFERNO ::
	IMGF=$ESP
else
	mformat -i "$IMG" -C -T 131072 -h 16 -s 63 -v EFI ::
	IMGF=$IMG
fi
mmd -i "$IMGF" ::/EFI ::/EFI/BOOT ::/aarch64 ::/cfg
mcopy -i "$IMGF" "$LOADER" ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "$IMGF" "$KERNEL" ::/aarch64/ivirtarm64
mcopy -i "$IMGF" "$CFG" ::/cfg/plan9.ini
mcopy -i "$IMGF" "$CFG" ::/plan9.ini
if [ -n "$INFERNO_GCE_TAR" ]; then
	printf 'fs0:\\EFI\\BOOT\\BOOTAA64.EFI\n' >"$TREE/startup.nsh"
	mcopy -i "$IMGF" "$TREE/startup.nsh" ::/startup.nsh
	python3 "$ROOT/scripts/mkgptdisk.py" "$IMG" "$IMGF" "$MIB"
fi

ls -l "$IMG"

# Compute Engine takes the image as a file named exactly disk.raw, alone
# in a gzipped tar in the old GNU tar format, and the raw file must be a
# whole number of gigabytes.  Identical to the amd64 recipe's block; the
# archive is not otherwise arm64-specific -- what makes the image arm64
# is BOOTAA64.EFI and the kernel inside it, and the instance it is
# imported for.  GNU tar spells the format oldgnu and the bsdtar on a
# Mac spells it gnutar, hence the probe.
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
	D=`dirname "$IMG"`
	B=`basename "$IMG"`
	[ "$B" != disk.raw ] && cp "$IMG" "$D/disk.raw"
	tar -C "$D" $TARFMT -czf "$INFERNO_GCE_TAR" disk.raw
	[ "$B" != disk.raw ] && rm -f "$D/disk.raw"
	echo "gce: $INFERNO_GCE_TAR ($TARFMT)"
	ls -l "$INFERNO_GCE_TAR"
fi
