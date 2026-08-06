#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
work=${QEMU9LEGACY_WORK:-"$root/.qemu-9legacy-amd64"}
base=$work/9legacy-qemu.img
overlay=$work/regress.qcow2
sourceiso=$work/inferno-source.iso
serial=$work/serial.log

mkdir -p "$work"

if test ! -f "$base"; then
	curl -fL http://9legacy.org/download/9legacy-qemu.img.bz2 -o "$base.bz2"
	if ! command -v gdd >/dev/null 2>&1; then
		echo 'need GNU dd (gdd) to extract the sparse 9legacy disk image' >&2
		exit 1
	fi
	bzcat "$base.bz2" | gdd of="$base" bs=1M conv=sparse status=none
fi

rm -f "$overlay"
qemu-img create -q -f qcow2 -F raw -b "$base" "$overlay"
QEMU9LEGACY_PREP_LOG="$work/prepare.log" \
expect "$root/tests/qemu-9legacy-amd64/prepare.exp" "$overlay"

stage=$work/source
rm -rf "$stage"
mkdir -p "$stage/inferno/tests/qemu-9legacy-amd64"
git -C "$root" ls-files --cached --others --exclude-standard -z |
	tar --null -T - -cf - -C "$root" |
	tar -xf - -C "$stage/inferno"
tar -C "$root" -cf - dis | tar -xf - -C "$stage/inferno"

rm -f "$sourceiso"
if command -v xorriso >/dev/null 2>&1; then
	xorriso -as mkisofs -quiet -o "$sourceiso" "$stage"
elif command -v hdiutil >/dev/null 2>&1; then
	hdiutil makehybrid -quiet -iso -joliet -o "$sourceiso" "$stage"
else
	echo 'need xorriso or hdiutil to create the source ISO' >&2
	exit 1
fi

: > "$serial"
QEMU9LEGACY_GUEST_RC='/n/inferno/inferno/tests/qemu-9legacy-amd64/guest.rc' \
QEMU9LEGACY_SERIAL="$serial" \
expect "$root/tests/qemu-9legacy-amd64/run.exp" "$overlay" "$sourceiso"

grep -q 'QEMU9LEGACY:PASS' "$serial"
echo '9legacy AMD64 QEMU regression passed'
