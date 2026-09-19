#!/bin/sh
# Build a UEFI-bootable ISO carrying the Inferno pc64 kernel.
#
# This is the boot path every cloud machine takes.  A rented bare-metal
# box, and every second-generation cloud VM, is UEFI class 3: there is no
# CSM, so the multiboot image os/inferno/pc64/qemu-boot.sh hands to
# QEMU's own -kernel loader cannot start there at all.  What starts is
# os/inferno/boot/efi/bootx64.efi, which the firmware loads from
# \EFI\BOOT\BOOTX64.EFI on an EFI system partition, and which then reads
# cfg/plan9.ini, builds the *e820= line from the UEFI memory map, calls
# ExitBootServices and jumps into the a.out kernel named by bootfile=.
#
# The ESP is built here with mtools rather than by the Plan 9 recipe in
# os/inferno/boot/efi/mkfile, which wants disk/format and dossrv.
#
# usage: scripts/mkinferno-efi-iso.sh [iso]
#
# INFERNO_KERNEL   kernel to install as /amd64/ipc64
# INFERNO_INI      extra plan9.ini lines, newline separated

set -e

ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

ISO=${1:-$ROOT/.qemu/inferno-efi.iso}
KERNEL=${INFERNO_KERNEL:-$ROOT/Inferno/amd64/ipc64}
LOADER=$ROOT/os/inferno/boot/efi/bootx64.efi
WORK=`mktemp -d "${TMPDIR:-/tmp}/inferno-iso.XXXXXX"`
TREE=$WORK/src
# Outside $TREE deliberately: the FAT is appended to the image as a real
# partition now, not carried inside the ISO filesystem as a file, so
# having it in both places would only make the image twice the size.
ESP=$WORK/efiboot.fat
mkdir -p "$TREE"

trap 'rm -rf "$WORK"' 0

echo "mk bootx64.efi"
(cd "$ROOT/os/inferno/boot/efi" && mk bootx64.efi)

test -f "$KERNEL" || { echo "no kernel: $KERNEL" >&2; exit 1; }

CFG=$TREE/cfg/plan9.ini
NSH=$TREE/startup.nsh
mkdir -p "$TREE/EFI/BOOT" "$TREE/amd64" "$TREE/cfg"
# console=0 is not optional.  pc64 links both a VGA console and a serial
# one; with no console= line it picks one silently and a serial capture
# shows nothing, which is indistinguishable from a hang.  The same trap
# os/inferno/pc64/qemu-boot.sh documents for the multiboot path.
cat >"$CFG" <<INI
bootfile=/amd64/ipc64
console=0
INI
if [ -n "$INFERNO_INI" ]; then
	printf '%s\n' "$INFERNO_INI" >>"$CFG"
fi
echo 'fs0:\EFI\BOOT\BOOTX64.EFI' >"$NSH"

echo "esp $ESP"
rm -f "$ESP"
mformat -i "$ESP" -C -T 32768 -h 16 -s 63 -v EFI ::
mmd -i "$ESP" ::/EFI ::/EFI/BOOT ::/amd64 ::/cfg
mcopy -i "$ESP" "$LOADER" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP" "$KERNEL" ::/amd64/ipc64
mcopy -i "$ESP" "$CFG" ::/cfg/plan9.ini
mcopy -i "$ESP" "$CFG" ::/plan9.ini
mcopy -i "$ESP" "$NSH" ::/startup.nsh

cp "$LOADER" "$TREE/EFI/BOOT/BOOTX64.EFI"
cp "$KERNEL" "$TREE/amd64/ipc64"
cp "$CFG" "$TREE/plan9.ini"

echo "iso $ISO"
mkdir -p `dirname "$ISO"`
rm -f "$ISO"
#
# An image as well as a disc.  With El Torito alone the ESP is reachable
# only by a machine that treats the file as a CD; a machine that treats
# it as a disk finds no partition table and does not boot, which is what
# happens when a provider writes the file to a volume and is what
# Vultr's custom-ISO path wants.
#
# The FAT is therefore appended as a real GPT partition of type 0xEF and
# El Torito is pointed at that same appended partition, so one file
# boots both ways and there is only one copy of the ESP in it.
# -partition_offset 16 leaves room for the protective MBR and the GPT
# header ahead of the filesystem.  (-isohybrid-gpt-basdat, which is the
# flag usually reached for, is for an image that also has a BIOS boot
# record: without one xorriso writes neither MBR nor GPT and says
# nothing, which is how this was found -- by looking for 0x55AA at
# offset 510 and not finding it.)
#
xorriso -as mkisofs -quiet -R -J -N -d -V INFERNO \
	-partition_offset 16 \
	-append_partition 2 0xef "$ESP" \
	-appended_part_as_gpt \
	-e '--interval:appended_partition_2:all::' -no-emul-boot \
	-o "$ISO" "$TREE"

ls -l "$ISO"
