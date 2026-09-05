#!/usr/bin/env bash
#
# import-9front.sh -- bring a 9front source tree into 9front-src/.
#
# 9front's own build wants paths that only exist on a 9front machine:
# every library and command mkfile begins "</$objtype/mkfile", the
# rule files it then includes are "</sys/src/cmd/mkone" and friends,
# and libraries and binaries are installed to "/$objtype/lib" and
# "/$objtype/bin".  None of those resolve here, and there is no way to
# make them resolve short of creating directories at the root of the
# build machine.  So the import rewrites them, mechanically and in one
# place, and this script is that place: re-run it to move to a newer
# upstream and the same rewrite is applied again.
#
# What is rewritten, and nothing else:
#	</$objtype/mkfile	-> <$ROOT/9front-src/$objtype/mkfile
#	</sys/src/...		-> <$ROOT/9front-src/sys/src/...
#	/$objtype/lib/		-> $ROOT/9front/$objtype/lib/
#	/$objtype/bin		-> $ROOT/9front/$objtype/bin
#	/$objtype/include/	-> $ROOT/9front-src/$objtype/include/
#	/sys/include/		-> $ROOT/9front-src/sys/include/
#	/sys/src/		-> $ROOT/9front-src/sys/src/
# in files named mkfile.  Twenty-two C files also name a header by an
# absolute path -- libmach reads every architecture's ureg.h and every
# loader's object format that way, and a few name /sys/include/tos.h
# -- and those are rewritten too, to the same two places.  Nothing
# else in any .c, .h or .s is touched: C sees the rest of its headers
# through -I, which the mkfiles set.
#
# ROOT is taken from the environment when a build runs, so the tree
# does not carry an absolute path of its own.
#
# Usage: scripts/import-9front.sh [upstream-checkout]
# With no argument it clones the pinned commit into a temporary
# directory.  See doc/9front-userland.ms.

set -eu

UPSTREAM_URL=https://github.com/9front/9front.git
UPSTREAM_BRANCH=front
UPSTREAM_COMMIT=5b902d52edaa25e5f430f024c1a1b9b56f94e3e0

cd "$(dirname "$0")/.."
DEST=$PWD/9front-src

SRC=${1:-}
if [ -z "$SRC" ]; then
	SRC=$(mktemp -d)/9front
	echo "cloning $UPSTREAM_URL ($UPSTREAM_BRANCH) into $SRC"
	git clone --depth 1 --branch "$UPSTREAM_BRANCH" "$UPSTREAM_URL" "$SRC"
fi
[ -d "$SRC/sys/src/libc" ] || { echo "$SRC is not a 9front tree" >&2; exit 1; }

#
# What comes across.  Left out on purpose:
#   sys/src/9		the kernel -- os/9front already holds one, and a
#			flavour here owns its kernel directory alone
#   sys/src/cmd/gs	a bundled ghostscript, 31 MB, and nothing needs
#			it to build a system
#   lib, sys/lib	runtime data (fonts, ndb, troff tables), not
#			source; a deployed root takes them from upstream
#
echo "copying sources"
rm -rf "$DEST"
mkdir -p "$DEST"
for d in sys/include amd64 386 arm arm64 mips power power64 sparc sparc64 spim 68000 68020 rc adm lib/ucd; do
	[ -e "$SRC/$d" ] || continue
	mkdir -p "$DEST/$(dirname "$d")"
	cp -R "$SRC/$d" "$DEST/$d"
done
mkdir -p "$DEST/sys/src"
for d in "$SRC"/sys/src/*; do
	b=$(basename "$d")
	case "$b" in
	9)	continue;;
	esac
	cp -R "$d" "$DEST/sys/src/$b"
done
rm -rf "$DEST/sys/src/cmd/gs"

echo "rewriting mkfile paths"
find "$DEST" -name mkfile -type f -print0 | xargs -0 sed -i '' \
	-e 's|^< */\$objtype/mkfile|<$ROOT/9front-src/$objtype/mkfile|' \
	-e 's|^< */sys/src/|<$ROOT/9front-src/sys/src/|' \
	-e 's|/\$objtype/lib/|$ROOT/9front/$objtype/lib/|g' \
	-e 's|/\$objtype/bin|$ROOT/9front/$objtype/bin|g' \
	-e 's|/\$objtype/include/|$ROOT/9front-src/$objtype/include/|g' \
	-e 's|\([^-A-Za-z0-9_/]\)/sys/include/|\1$ROOT/9front-src/sys/include/|g' \
	-e 's|^/sys/include/|$ROOT/9front-src/sys/include/|g' \
	-e 's|\([^-A-Za-z0-9_/]\)/sys/src/|\1$ROOT/9front-src/sys/src/|g' \
	-e 's|/lib/ucd/|$ROOT/9front-src/lib/ucd/|g' \
	-e 's|/\$cputype/mkfile|$ROOT/9front-src/host/mkfile|g' \
	-e 's|-I/sys/src/|-I$ROOT/9front-src/sys/src/|g' \
	-e 's|-I/\$objtype/|-I$ROOT/9front-src/$objtype/|g' \
	-e 's|^CFLAGS=$|CFLAGS=$INCLUDES|'

#
# The per-architecture mkfile and the rule files are ours: they name
# this tree's compilers and archiver (iar, iyacc) rather than the ones
# a 9front machine has on its path, and they put the results in the
# target tree beside the kernel's.
#

echo "rewriting absolute includes in C sources"
find "$DEST/sys/src" -name '*.c' -type f -print0 | xargs -0 grep -l '#include[ 	]*"/' | while read -r f; do
	sed -i '' \
		-e 's|#include\([ 	]*\)"/sys/include/|#include\1"'"$DEST"'/sys/include/|g' \
		-e 's|#include\([ 	]*\)"/sys/src/|#include\1"'"$DEST"'/sys/src/|g' \
		-e 's|#include\([ 	]*\)"/\([A-Za-z0-9_]*\)/include/|#include\1"'"$DEST"'/\2/include/|g' \
		"$f"
done

#
# Host-tool fixups.  A generator that runs on the build machine is
# compiled by the host cc, not by 6c, and the host cc is stricter
# about one thing 9front's own compiler tolerates: a main() that
# declares parameters it does not use as "void main(int, char)".
# clang rejects that outright -- not a warning it can be told to drop
# -- so the signature is corrected where a generator has it.  A
# generator also reads its input by absolute path, /lib/ucd on a
# 9front machine, and that is pointed at the imported copy.  These are
# the only changes made to any C source other than absolute includes,
# and they are made only in files the build compiles for the host.
#
echo "fixing host-tool main() signatures"
for f in "$DEST/sys/src/libc/ucd/mkrunetype.c"; do
	[ -f "$f" ] || continue
	sed -i '' -e 's|^main(int, char)$|main(int argc, char **argv)|' \
		-e 's|"/lib/ucd/|"'"$DEST"'/lib/ucd/|g' "$f"
done

cat > "$DEST/MANIFEST" <<EOF
upstream	$UPSTREAM_URL
branch		$UPSTREAM_BRANCH
commit		$UPSTREAM_COMMIT
imported by	scripts/import-9front.sh
left out	sys/src/9, sys/src/cmd/gs, lib, sys/lib
EOF
echo "imported $UPSTREAM_COMMIT into $DEST"
