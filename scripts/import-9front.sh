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
# Everything under 9front-src is produced by this script and nothing
# else.  What is ours -- the mk, ar and yacc shims, the host compiler
# wrappers -- lives outside it, in 9front-glue, so that the "rm -rf"
# below can never take it away.  Editing a file under 9front-src by
# hand is a mistake: the next import undoes it.  If a change is
# needed, it goes here, as a rule.
#
# What is rewritten, and nothing else:
#	$ROOT/			-> /		(see below)
#	</$objtype/mkfile	-> <$ROOT/9front-src/$objtype/mkfile
#	</sys/src/...		-> <$ROOT/9front-src/sys/src/...
#	/$objtype/lib/		-> $ROOT/9front/$objtype/lib/
#	/$objtype/bin		-> $ROOT/9front/$objtype/bin
#	/$objtype/include/	-> $ROOT/9front-src/$objtype/include/
#	/$objtype/ anything else	-> $ROOT/9front/$objtype/
#	/sys/include/		-> $ROOT/9front-src/sys/include/
#	/sys/src/		-> $ROOT/9front-src/sys/src/
#	/lib/ucd/		-> $ROOT/9front-src/lib/ucd/
#	/$cputype/mkfile	-> $ROOT/9front-glue/host/mkfile
# in files named mkfile and in the rule files beside them.  Those rule
# files also name ar and yacc directly, and this tree's are iar and
# iyacc, so the two calls become $AR and $YACC, which the
# per-architecture mkfile sets.  Thirty-five C and header files name
# an include by an absolute path -- libmach reads every architecture's
# ureg.h and every loader's object format that way, and a few name
# /sys/include/tos.h -- and those lose the leading slash and are found
# through -I$ROOT/9front-src instead.  Nothing else in any .c, .h or
# .s is touched: C sees the rest of its headers through -I, which the
# mkfiles set.
#
# No absolute path of the build machine is written into the tree.
# ROOT is taken from the environment when a build runs, and the two
# paths that are not includes -- the Unicode tables mkrunetype reads
# -- are made relative to the directory the recipe runs in.
#
# One part of the tree already has this idea.  postscript's mkfiles
# install to $ROOT/$objtype/bin and $ROOT/sys/lib, where ROOT is
# empty on a real machine and names a staging root otherwise: the
# same thing this tree means by it, but pointing at a place that is
# not where these libraries and binaries go.  So upstream's $ROOT is
# taken off first, leaving the plain absolute path every other mkfile
# writes, and the rules below then put it where it belongs.
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
ARCHS="amd64 386 arm arm64 mips power power64 sparc sparc64 spim 68000 68020"
for d in sys/include $ARCHS rc adm lib/ucd; do
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
find "$DEST" \( -name mkfile -o -name 'mkfile.*' -o -name mkone -o -name mkmany \
	-o -name mklib -o -name mksyslib -o -name mktest -o -name mkproto \
	-o -name config -o -name portmkfile -o -name mkupas \) \
	-type f -print0 | xargs -0 /usr/bin/sed -i '' \
	-e 's|\$ROOT/|/|g' \
	-e 's|^< */\$objtype/mkfile|<$ROOT/9front-src/$objtype/mkfile|' \
	-e 's|^< */sys/src/|<$ROOT/9front-src/sys/src/|' \
	-e 's|/\$objtype/lib/|$ROOT/9front/$objtype/lib/|g' \
	-e 's|/\$objtype/bin|$ROOT/9front/$objtype/bin|g' \
	-e 's|/\$objtype/include/|$ROOT/9front-src/$objtype/include/|g' \
	-e 's|\([^-A-Za-z0-9_/]\)/sys/include/|\1$ROOT/9front-src/sys/include/|g' \
	-e 's|^/sys/include/|$ROOT/9front-src/sys/include/|g' \
	-e 's|\([^-A-Za-z0-9_/]\)/sys/src/|\1$ROOT/9front-src/sys/src/|g' \
	-e 's|/lib/ucd/|$ROOT/9front-src/lib/ucd/|g' \
	-e 's|/\$cputype/mkfile|$ROOT/9front-src/$cputype/mkfile|g' \
	-e 's|-I/sys/src/|-I$ROOT/9front-src/sys/src/|g' \
	-e 's|-I/\$objtype/|-I$ROOT/9front-src/$objtype/|g' \
	-e 's|\([^-A-Za-z0-9_/]\)/\$objtype/|\1$ROOT/9front/$objtype/|g' \
	-e 's|^/\$objtype/|$ROOT/9front/$objtype/|g' \
	-e 's|^CFLAGS=$|CFLAGS=$INCLUDES|' \
	-e 's|^\(	*\)ar vu |\1$AR $ARFLAGS |' \
	-e 's|^\(	*\)yacc |\1$YACC |'

#
# The same files again, for the paths that do not go through a
# variable.  A mkfile that names an architecture outright is either
# including that architecture's mkfile, which is source, or installing
# into its bin, which is the target root; a mkfile that names
# /sys/lib, /rc/bin, /acme or /lib is installing runtime data, and
# those live in the target root too.  $ROOT/9front is that root: what
# a deployed 9front would have at /.  Extended syntax, because this
# wants alternation, and a separate pass so the rules above keep
# theirs.
#
ARCHRE='386|amd64|arm|arm64|mips|power|power64|sparc|sparc64|spim|68000|68020'
find "$DEST" \( -name mkfile -o -name 'mkfile.*' -o -name mkone -o -name mkmany \
	-o -name mklib -o -name mksyslib -o -name mktest -o -name mkproto \
	-o -name config -o -name portmkfile -o -name mkupas \) \
	-type f -print0 | xargs -0 /usr/bin/sed -i '' -E \
	-e "s%^< */($ARCHRE)/mkfile%<\$ROOT/9front-src/\1/mkfile%" \
	-e "s%([^-A-Za-z0-9_/])/($ARCHRE)(/|\$)%\1\$ROOT/9front/\2\3%g" \
	-e 's%([^-A-Za-z0-9_/])/(sys/lib|rc/bin|acme|lib/font|lib/keyboard|sys/doc)(/|$)%\1$ROOT/9front/\2\3%g' \
	-e 's%^/(sys/lib|rc/bin|acme)/%$ROOT/9front/\1/%'

#
# The per-architecture mkfile is what every library and command mkfile
# includes, so it is where the names that differ from a 9front
# machine's go: the shell the recipes run under, this tree's archiver
# and yacc, where the headers are, and where the results are
# installed.  Upstream's own file already names the compilers for the
# architecture, so it is kept and wrapped rather than replaced.
#
echo "setting up the per-architecture mkfiles"
for a in $ARCHS; do
	[ -f "$DEST/$a/mkfile" ] || continue
	{
		cat <<'EOF'
#
# The per-architecture mkfile every 9front library and command mkfile
# includes.  The middle of it is upstream's, naming the compilers for
# this architecture; scripts/import-9front.sh wraps it in what differs
# on a build machine that is not 9front, and rewrites it again on
# every import, so do not edit it here.
#
# ROOT must be in the environment.  Everything below, and every mkfile
# the import rewrote, is written in terms of it.
#

# The shell every recipe runs under.  9front's mkfiles are rc scripts,
# and a recursive mk does not inherit a MKSHELL given on the command
# line, so it is set here, where all of them include it.  mkrc parses
# rc's syntax; this makes it run rc as well, through mkshell() in
# utils/mk/Posix.c.  The name is MKSH, not MKSHELL: mkfiles already in
# this tree set MKSHELL and have always been built under sh whatever
# it said.
MKSH=$RCSHELL

EOF
		cat "$DEST/$a/mkfile"
		cat <<'EOF'

# this tree's archiver and yacc, not the host's
AR=iar
ARFLAGS=vu
YACC=iyacc

# 9front's own headers, and nothing from the Inferno side: a 9front
# program sees the system it is being built for and no other.  The
# tree root is on the path too, for the thirty-five sources that name
# a header by what was an absolute path on a 9front machine.
INCLUDES=-I$ROOT/9front-src/$objtype/include -I$ROOT/9front-src/sys/include -I$ROOT/9front-src
CFLAGS=$CFLAGS $INCLUDES

BIN=$ROOT/9front/$objtype/bin
LIBDIR=$ROOT/9front/$objtype/lib
EOF
	} > "$DEST/$a/mkfile.new"
	mv "$DEST/$a/mkfile.new" "$DEST/$a/mkfile"
done

#
# A source that names a header by an absolute path loses the leading
# slash and is found through -I$ROOT/9front-src, which the
# per-architecture mkfile puts on every compile.  Both spellings are
# rewritten -- "..." and <...> -- because both appear.  Writing the
# build machine's own path in here instead would work, and would make
# the tree unusable anywhere else.
#
echo "rewriting absolute includes in C sources"
find "$DEST/sys/src" \( -name '*.c' -o -name '*.h' \) -type f -print0 \
	| xargs -0 grep -l '#include[ 	]*[<"]/' \
	| while read -r f; do
	/usr/bin/sed -i '' \
		-e 's|#include\([ 	]*\)"/|#include\1"|' \
		-e 's|#include\([ 	]*\)</|#include\1<|' \
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
# 9front machine.  That is not an include and no -I finds it, so it is
# made relative to the directory the recipe runs in, four levels below
# the tree root.  These are the only changes made to any C source
# other than absolute includes, and they are made only in files the
# build compiles for the host.
#
#
# One more change to the same file, and this one is a bug rather than
# a difference of taste.  findlongchain() walks a rune's decomposition
# chain with
#
#	for(x = i, n = 0; r1 = mydecomp[x]>>16; x = r1)
#
# and mydecomp is an array of signed int.  A singleton decomposition
# whose target has bit 15 set -- U+F900, the first CJK compatibility
# ideograph, decomposes to U+8C48 -- is stored as 0x8C480000, which is
# negative, and the arithmetic shift sign-extends it to 0xFFFF8C48.
# That is not in the range the loop recognises as a marker, so it
# becomes the next index, and the walk reads mydecomp[-1].  On a
# 9front machine whatever precedes mydecomp in bss is zero and the
# loop stops there by luck; here the array before it is mytolower,
# every element of which main() has just set to -1, so the walk
# follows -1 to -1 forever.  Shifting through unsigned gives the
# reading the loop wants and the chain then ends where it should.
# This is upstream's bug, not the import's; it is fixed here because
# the tree under 9front-src is generated and no edit to it survives.
#
echo "fixing host-tool main() signatures"
for f in "$DEST/sys/src/libc/ucd/mkrunetype.c"; do
	[ -f "$f" ] || continue
	/usr/bin/sed -i '' -e 's|^main(int, char)$|main(int argc, char **argv)|' \
		-e 's|"/lib/ucd/|"../../../../lib/ucd/|g' \
		-e 's|r1 = mydecomp\[x\]>>16|r1 = (uint)mydecomp[x]>>16|' "$f"
done

#
# The tree-wide .gitignore treats a one-letter suffix as compiler
# output and *.patch as a patch someone left lying about.  Under two
# of 9front's test directories they are neither -- they are the input
# and the expected output of the tests -- and an import that quietly
# dropped them would leave a tree that does not match upstream.
#
#
# $cputype names the architecture the build machine runs, and a
# mkfile reaches for it when it needs a tool that runs here rather
# than on 9front: awk builds maketab that way, libc/ucd greps it for
# a compiler.  The build sets cputype=host, and this is that
# architecture's mkfile -- a copy of the one in 9front-glue, which is
# where it is maintained.
#
mkdir -p "$DEST/host"
cp "$PWD/9front-glue/host/mkfile" "$DEST/host/mkfile"

#
# An awk script that the build runs starts "#!/bin/awk -f", which is
# where awk is on a 9front machine and not where it is here.  These
# are generators -- they make a table from a header and are never
# installed -- so the line is pointed at the awk this machine has.
# Nothing else's first line is touched.
#
find "$DEST/sys/src" -name '*.awk' -type f -print0 | xargs -0 /usr/bin/sed -i '' \
	-e '1s|^#!/bin/awk|#!/usr/bin/awk|'

cat > "$DEST/.gitignore" <<'EOF'
# written by scripts/import-9front.sh; see the note there
!sys/src/cmd/awk/test/*
!sys/src/cmd/test/patch/*.patch
EOF

cat > "$DEST/MANIFEST" <<EOF
upstream	$UPSTREAM_URL
branch		$UPSTREAM_BRANCH
commit		$UPSTREAM_COMMIT
imported by	scripts/import-9front.sh
left out	sys/src/9, sys/src/cmd/gs, lib, sys/lib
EOF
echo "imported $UPSTREAM_COMMIT into $DEST"
