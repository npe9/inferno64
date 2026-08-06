#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
work=${QEMU9FRONT_WORK:-"$root/.qemu-9front-amd64"}
base=$work/9front-amd64.qcow2
overlay=$work/regress.qcow2
sourceiso=$work/inferno-source.iso
serial=$work/serial.log

mkdir -p "$work"

if test ! -f "$base"; then
	index=$(curl -fsSL https://build.9front.org/)
	image=$(printf '%s\n' "$index" | sed -n 's,.*href="\(/9front/9front-[0-9][0-9]*\.amd64\.qcow2\.gz\)".*,\1,p' | sed -n '1p')
	test -n "$image"
	curl -fL "https://build.9front.org$image" -o "$base.gz"
	gzip -dc "$base.gz" > "$base"
fi

rm -f "$overlay"
qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$overlay"

stage=$work/source
rm -rf "$stage"
mkdir -p "$stage/inferno/tests/qemu-9front-amd64"
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
QEMU9FRONT_GUEST_RC='/n/inferno/inferno/tests/qemu-9front-amd64/guest.rc' \
QEMU9FRONT_SERIAL="$serial" \
expect "$root/tests/qemu-9front-amd64/run.exp" "$overlay" "$sourceiso"

grep -q 'QEMU9FRONT:PASS' "$serial"
echo '9front AMD64 QEMU regression passed'
