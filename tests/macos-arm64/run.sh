#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

if test "$(uname -s)" != Darwin || test "$(uname -m)" != arm64; then
	echo 'MACOS-ARM64: unsupported host (requires Darwin arm64)' >&2
	exit 2
fi

PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
TMPDIR=${TMPDIR:-/tmp}
export TMPDIR

if ! command -v mk >/dev/null 2>&1; then
	echo 'MACOS-ARM64: mk not found in MacOSX/arm64/bin or PATH' >&2
	exit 2
fi

echo MACOS-ARM64:COCOA-BUILD-BEGIN
(cd "$root/emu/MacOSX" && mk CONF=emu-cocoa install)

echo MACOS-ARM64:CONSOLE-BUILD-BEGIN
(cd "$root/emu/MacOSX" && mk CONF=emu-g install)

echo MACOS-ARM64:DRAW3D-BUILD-BEGIN
(cd "$root/appl/math" && mk install)

emu="$root/MacOSX/arm64/bin/emu-g"
test -x "$emu"

echo MACOS-ARM64:SMOKE-BEGIN
"$emu" -r "$root" sh -c 'test -e /dis/math/draw3d.dis; test -e /dis/math/draw3ddev.dis; echo MACOS-ARM64:PASS'
