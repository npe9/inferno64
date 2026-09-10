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
# usage: scripts/mkinferno-efi-disk-arm64.sh [image]
#
# INFERNO_KERNEL   kernel to install as /aarch64/ivirtarm64
# INFERNO_INI      extra plan9.ini lines, newline separated

set -e

ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

IMG=${1:-$ROOT/.qemu/inferno-efi-arm64.img}
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
mformat -i "$IMG" -C -T 131072 -h 16 -s 63 -v EFI ::
mmd -i "$IMG" ::/EFI ::/EFI/BOOT ::/aarch64 ::/cfg
mcopy -i "$IMG" "$LOADER" ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "$IMG" "$KERNEL" ::/aarch64/ivirtarm64
mcopy -i "$IMG" "$CFG" ::/cfg/plan9.ini
mcopy -i "$IMG" "$CFG" ::/plan9.ini

ls -l "$IMG"
