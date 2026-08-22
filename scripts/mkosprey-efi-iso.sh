#!/bin/sh
# Build the Osprey EFI boot ISO on a host system.
#
# The Plan 9 recipes in os/boot/efi/mkfile build the EFI System Partition
# image with disk/format and dossrv, which only exist on Plan 9.  On a
# hosted build machine we use mtools and xorriso instead.  Everything the
# ISO contains is still produced by mk.
#
# usage: scripts/mkosprey-efi-iso.sh [iso]

set -e

ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

ISO=${1:-$ROOT/.qemu/osprey-efi.iso}
KERNEL=$ROOT/os/osprey/pc64/9pc64
LOADER=$ROOT/os/boot/efi/bootx64.efi
ESP=$ROOT/os/boot/efi/efiboot.fat
TREE=`mktemp -d "${TMPDIR:-/tmp}/osprey-iso.XXXXXX"`

trap 'rm -rf "$TREE"' 0

echo "mk bootx64.efi"
(cd "$ROOT/os/boot/efi" && mk bootx64.efi)

test -f "$KERNEL" || { echo "no kernel: $KERNEL" >&2; exit 1; }

CFG=$TREE/cfg/plan9.ini
NSH=$TREE/startup.nsh
mkdir -p "$TREE/EFI/BOOT" "$TREE/amd64" "$TREE/cfg"
cat >"$CFG" <<'INI'
bootfile=/amd64/9pc64
console=0
INI
echo 'fs0:\EFI\BOOT\BOOTX64.EFI' >"$NSH"

echo "esp $ESP"
rm -f "$ESP"
mformat -i "$ESP" -C -T 32768 -h 16 -s 63 -v EFI ::
mmd -i "$ESP" ::/EFI ::/EFI/BOOT ::/amd64 ::/cfg
mcopy -i "$ESP" "$LOADER" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP" "$KERNEL" ::/amd64/9pc64
mcopy -i "$ESP" "$CFG" ::/cfg/plan9.ini
mcopy -i "$ESP" "$CFG" ::/plan9.ini
mcopy -i "$ESP" "$NSH" ::/startup.nsh

echo "tree $TREE"
cp "$LOADER" "$TREE/EFI/BOOT/BOOTX64.EFI"
cp "$KERNEL" "$TREE/amd64/9pc64"
cp "$ESP" "$TREE/efiboot.fat"
cp "$CFG" "$TREE/plan9.ini"

echo "iso $ISO"
rm -f "$ISO"
xorriso -as mkisofs -quiet -R -J -N -d -V OSPREY \
	-e efiboot.fat -no-emul-boot \
	-o "$ISO" "$TREE"

ls -l "$ISO"
