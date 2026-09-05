#!/usr/bin/env bash
#
# mkiso9front.sh -- build a bootable 9front ISO out of this tree.
#
# The root is $ROOT/9front, which scripts/mkroot9front.sh assembles:
# the 646 programs the build installed, the runtime data no compiler
# makes, and the kernel os/9front builds.  This puts the boot loaders
# beside them and turns the whole of it into an ISO9660 image that is
# both the thing the machine boots and the file system it runs on --
# a live CD, which is also how 9front ships.
#
# What runs here rather than on 9front:
#
#	the loaders	built by this tree's own 8c/8a/8l and 6c/6a/6l
#			from 9front's sys/src/boot.  aux/aout2efi, which
#			turns the a.out 6l writes into the PE32+ image
#			firmware loads, is 9front's own source built for
#			this machine; see 9front-glue/host/machhdr.c.
#	efiboot.fat	9front makes the EFI System Partition image with
#			disk/format and dossrv, which are Plan 9 file
#			servers.  Here it is mtools, the same way
#			scripts/mkosprey-efi-iso.sh does it.
#	disk/mk9660	9front's own, built for this machine.  It is one
#			line of rc over disk/dump9660 and both are in
#			9front/host/bin/disk.
#
# The image boots two ways: El Torito no-emulation with 386/9bootiso
# for a BIOS, and an EFI System Partition holding bootia32.efi and
# bootx64.efi for firmware.  Either loader reads /cfg/plan9.ini and
# the kernel out of the ISO itself.
#
# Usage: scripts/mkiso9front.sh [-o objtype] [iso]
# Default: .qemu/9front.$objtype.iso, beside the other images the
# tests boot.

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD

objtype=amd64
if [ "${1:-}" = "-o" ]; then objtype=$2; shift 2; fi

case $objtype in
amd64)	kernel=9pc64;;
386)	kernel=9pc;;
*)	echo "mkiso9front: no ISO for $objtype" >&2; exit 1;;
esac

ISO=${1:-$ROOT/.qemu/9front.$objtype.iso}
mkdir -p "$(dirname "$ISO")"
DEST=$ROOT/9front
host=$ROOT/9front/host/bin

for t in mformat mmd mcopy; do
	command -v "$t" >/dev/null || {
		echo "mkiso9front: no $t; install mtools" >&2; exit 1; }
done

#
# The kernel, taken from the flavour directory that builds it rather
# than from whatever an earlier run of mkroot9front.sh left in the
# root, so the image always carries the kernel this tree has now.
#
case $objtype in
amd64)	built=$ROOT/os/9front/pc64/$kernel;;
386)	built=$ROOT/os/9front/pc/$kernel;;
esac
if [ -f "$built" ]; then
	mkdir -p "$DEST/$objtype"
	cp "$built" "$DEST/$objtype/$kernel"
elif [ ! -f "$DEST/$objtype/$kernel" ]; then
	echo "mkiso9front: no kernel at $built" >&2
	exit 1
fi
[ -d "$DEST/rc/bin" ] || {
	echo "mkiso9front: $DEST is not a root; run scripts/mkroot9front.sh" >&2
	exit 1; }

#
# The loaders.  Their mkfiles include nothing -- a boot loader is
# freestanding -- so they get the compilers and the include path from
# mk9front.sh's environment rather than from an architecture mkfile.
#
echo "loaders"
bash "$ROOT/scripts/mk9front.sh" -o 386 9front-src/sys/src/boot/pc 9bootiso
bash "$ROOT/scripts/mk9front.sh" -o 386 9front-src/sys/src/boot/efi bootia32.efi
bash "$ROOT/scripts/mk9front.sh" 9front-src/sys/src/boot/efi bootx64.efi

mkdir -p "$DEST/386" "$DEST/cfg"
cp "$ROOT/9front-src/sys/src/boot/pc/9bootiso" "$DEST/386/9bootiso"
cp "$ROOT/9front-src/sys/src/boot/efi/bootia32.efi" "$DEST/386/bootia32.efi"
cp "$ROOT/9front-src/sys/src/boot/efi/bootx64.efi" "$DEST/386/bootx64.efi"

#
# The EFI System Partition, as a FAT image inside the ISO.  1 MB is
# what 9front's own mkfile makes and the three loaders fit in it with
# room to spare.  Firmware looks for \EFI\BOOT\BOOTX64.EFI; the names
# are written lower case because that is what 9front writes and FAT
# does not distinguish them.
#
echo "efiboot.fat"
esp=$DEST/386/efiboot.fat
rm -f "$esp"
dd if=/dev/zero of="$esp" bs=1024 count=1024 status=none
mformat -i "$esp" -v EFI ::
mmd -i "$esp" ::/efi ::/efi/boot
mcopy -i "$esp" "$DEST/386/bootia32.efi" ::/efi/boot/bootia32.efi
mcopy -i "$esp" "$DEST/386/bootx64.efi" ::/efi/boot/bootx64.efi
# Firmware that drops to the EFI shell instead of booting removable
# media -- the edk2 build the tests run under does -- runs
# startup.nsh off the first file system it finds.  9front's own ISO
# has no such file and does not need one on real hardware; this is a
# line for the shell to take, and costs 32 bytes.
nsh=$(mktemp)
printf 'fs0:\\efi\\boot\\bootx64.efi\n' > "$nsh"
mcopy -i "$esp" "$nsh" ::/startup.nsh
rm -f "$nsh"

#
# The configuration the loader reads.  cdboot=yes is what makes
# bootrc pick the 9660 file system it was booted from as the root:
# see showlocaldev in os/9front/boot/local.rc.  Without it the boot
# stops at the bootargs prompt.
#
echo "cfg/plan9.ini"
cat > "$DEST/cfg/plan9.ini" <<INI
# written by scripts/mkiso9front.sh
cdboot=yes
bootfile=/$objtype/$kernel
console=0
INI
if [ -n "${ISO9FRONT_INI:-}" ]; then
	printf '%s\n' "$ISO9FRONT_INI" >> "$DEST/cfg/plan9.ini"
fi

#
# The proto: everything in the root, owned by sys.  A proto file is
# how Plan 9 says which files go into an image; "+" means the whole
# subtree, and the whole subtree is what a live CD is.
#
proto=$(mktemp)
trap 'rm -f "$proto"' 0
#
# skip names what is in $ROOT/9front for the build's sake and has no
# business in a root: the host tools, which are this machine's
# binaries and not 9front's, the sweep's logs, the cached directory
# lists mk9front.sh keeps, and any image left here by an earlier run.
#
cat > "$proto" <<'PROTO'
uid=sys
gid=sys
skip=^(host|sweep|dirs\.[a-z0-9]+|.*\.iso)$
+
PROTO

echo "iso $ISO"
rm -f "$ISO"
"$host/disk/mk9660" -c9j \
	-B 386/9bootiso -E 386/efiboot.fat \
	-p "$proto" -s "$DEST" \
	-v "9front ($objtype) built by inferno64" "$ISO"

ls -l "$ISO"
