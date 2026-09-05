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
#	a line that is just "ROOT="	deleted	(see below)
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
# writes, and the rules below then put it where it belongs.  Those
# mkfiles also set ROOT to nothing, which here would undo the whole
# arrangement, so that line goes as well.
#
# Usage: scripts/import-9front.sh [upstream-checkout]
# With no argument it clones the pinned commit into a temporary
# directory.  See doc/9front-userland.ms.

set -eu

#
# Byte semantics, not character semantics: some of 9front's sources
# are not UTF-8 (an ISO 8859 header among them) and sed under a UTF-8
# locale stops at the first byte it cannot decode -- "RE error:
# illegal byte sequence" -- taking the rest of the import with it.
#
LC_ALL=C
export LC_ALL

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
#			source; a deployed root takes them from upstream.
#			lib/ucd and sys/lib/yaccpar are the exceptions
#			and do come across: libc generates its Unicode
#			tables from one and every yacc grammar in the
#			tree is built from the other, which makes them
#			build inputs rather than data.  lib/keyboard and
#			sys/lib/scsicodes are two more of the same kind:
#			kbdfs's latin1.h comes from the first and
#			nusb/disk's scsierrs.c from the second
#
echo "copying sources"
rm -rf "$DEST"
mkdir -p "$DEST"
ARCHS="amd64 386 arm arm64 mips power power64 sparc sparc64 spim 68000 68020"
COPIED="sys/include $ARCHS rc adm lib/ucd lib/keyboard sys/lib/yaccpar sys/lib/yaccpars sys/lib/scsicodes sys/src"
for d in sys/include $ARCHS rc adm lib/ucd lib/keyboard sys/lib/yaccpar sys/lib/yaccpars sys/lib/scsicodes; do
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

#
# The rewrite itself, as a function: the mkfiles get it, and so do the
# handful of scripts a mkfile runs, which name the same paths.
#
rewrite1()
{
	/usr/bin/sed -i '' \
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
	-e 's|/lib/keyboard|$ROOT/9front-src/lib/keyboard|g' \
	-e 's|/sys/lib/scsicodes|$ROOT/9front-src/sys/lib/scsicodes|g' \
	-e 's|/\$cputype/mkfile|$ROOT/9front-src/$cputype/mkfile|g' \
	-e 's|-I/sys/src/|-I$ROOT/9front-src/sys/src/|g' \
	-e 's|-I/sys/include/|-I$ROOT/9front-src/sys/include/|g' \
	-e 's|-I/\$objtype/|-I$ROOT/9front-src/$objtype/|g' \
	-e 's|\([^-A-Za-z0-9_/]\)/\$objtype/|\1$ROOT/9front/$objtype/|g' \
	-e 's|^/\$objtype/|$ROOT/9front/$objtype/|g' \
	-e 's|^CFLAGS=$|CFLAGS=$INCLUDES|' \
	-e 's|^\(	*\)ar vu |\1$AR $ARFLAGS |' \
	-e 's|^\(	*\)yacc |\1$YACC |' \
	-e 's|#!/bin/rc|#!/usr/bin/env rc|g' \
	-e '/^ROOT=$/d' \
		"$@"
}

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
# The rule before last is where a mkfile sets CFLAGS outright instead
# of adding to it.  The per-architecture mkfile puts the headers on
# the command line through CFLAGS, and a mkfile that overwrites it
# takes them away again: postscript's p9bitpost says
# "CFLAGS=-w -I../common" and then cannot find u.h.  On a 9front
# machine the compiler knows where its own headers are and no -I is
# needed, which is why upstream can write that.  Here the include
# path is added back.  LDFLAGS is the same story: mkone clears it, and
# the loader then has nowhere to look for the three audio libraries
# and map's libmap.  Neither rule touches an assignment that runs on
# to the next line: appending after the backslash ends the
# continuation, and the syntax error that makes shows up two lines
# later, where nothing looks wrong.
#
# The last rule is a namespace, not a path.  APE's libmp and libsec
# are built from the sources of the ones beside them, and their
# mkfiles work out which files the architecture has in assembly by
# binding that architecture's directory into view and listing it.
# There is no bind here.  The list is what is wanted, not the
# namespace, so reduce -- the script that does the listing -- is
# pointed straight at the directory instead.  Without this the C
# versions of the routines the assembly also defines go into the
# archive beside them and the archiver refuses the duplicate.
#
ARCHRE='386|amd64|arm|arm64|mips|power|power64|sparc|sparc64|spim|68000|68020'
rewrite2()
{
	/usr/bin/sed -i '' -E \
	-e "s%^< */($ARCHRE)/mkfile%<\$ROOT/9front-src/\1/mkfile%" \
	-e "s%([^-A-Za-z0-9_/])/($ARCHRE)(/|\$)%\1\$ROOT/9front/\2\3%g" \
	-e 's%([^-A-Za-z0-9_/])/(sys/lib|rc/bin|acme|lib/font|sys/doc)(/|$)%\1$ROOT/9front/\2\3%g' \
	-e 's%^/(sys/lib|rc/bin|acme)/%$ROOT/9front/\1/%' \
	-e 's%bind -a \.\./\.\./\.\./\.\./(libmp|libsec)/[$]objtype \.\./[$]objtype;%objtype=../../../\1/$objtype;%' \
	-e '/^CFLAGS=[^\\]*$/{/[$](CFLAGS|INCLUDES)/!s/$/ $INCLUDES/;}' \
	-e '/^LDFLAGS=[^\\]*$/{/[$]ROOT/!s%$% -L$ROOT/9front-src%;}' \
		"$@"
}

echo "rewriting mkfile paths"
mkfiles=$(mktemp)
find "$DEST" \( -name mkfile -o -name 'mkfile.*' -o -name mkone -o -name mkmany \
	-o -name mklib -o -name mksyslib -o -name mktest -o -name mkproto \
	-o -name config -o -name portmkfile -o -name mkupas \) \
	-type f -print > "$mkfiles"
while IFS= read -r f; do
	rewrite1 "$f"
	rewrite2 "$f"
done < "$mkfiles"
rm -f "$mkfiles"

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

# 9front's own headers, and nothing from the Inferno side: a 9front
# program sees the system it is being built for and no other.  The
# tree root is on the path too, for the thirty-five sources that name
# a header by what was an absolute path on a 9front machine.
#
# This is set before the upstream part below rather than after,
# because that part reads sys/src/mkfile.proto, which is where
# CFLAGS is built out of it: "CFLAGS=-FTVw $INCLUDES".  Setting
# CFLAGS again afterwards would append the includes a second time in
# every recursive mk, which inherits the parent's CFLAGS through the
# environment.
INCLUDES=-I$ROOT/9front-src/$objtype/include -I$ROOT/9front-src/sys/include -I$ROOT/9front-src

EOF
		cat "$DEST/$a/mkfile"
		cat <<'EOF'

# this tree's archiver, and 9front's own yacc built for this machine
# (9front-glue/bin/yacc, first on the path, is what finds it)
AR=iar
ARFLAGS=vu
YACC=yacc

# where the loader looks for a library a #pragma names without a
# path: the target tree for the system's own, and the source tree for
# the three audio libraries that are built where they sit.  Assigned
# rather than appended, for the reason given against INCLUDES above:
# nothing sets LDFLAGS before this except a parent mk.
LDFLAGS=-L$ROOT/9front-src

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
find "$DEST/sys/src" "$DEST/sys/include" "$DEST"/*/include \
	\( -name '*.c' -o -name '*.h' \) -type f -print0 \
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
#
# cpp is a host tool too, and the only one that is also built for
# 9front: pcc pipes every APE source through it because neither
# 9front's compiler nor this tree's understands "#if".  Its nlist.c
# declares getopt, optarg and optind and then uses none of them --
# 9front's libc has no getopt at all -- and on this build machine the
# declaration collides with the one in the host's unistd.h, which
# lib9.h has already pulled in.  Removing three declarations of things
# nothing calls is safe for both targets.
#
#
# APE's headers name the library that goes with them with
#
#	#pragma lib "/$M/lib/ape/libap.a"
#
# and the loader takes a name beginning with a slash as the path to
# open, which on this machine is nothing.  The rest of 9front's
# headers write the same pragma without a path -- "libdraw.a" -- and
# the loader then looks through its library directories, which is
# where these libraries are.  So the APE headers are made to say what
# the others say.  This is what puts libap in the list the loader
# rescans until nothing is undefined; a library named only as a file
# on the command line is read once, before the loader has pulled in
# the libc member that needs it.
#
echo "making the library pragmas searchable"
find "$DEST/sys/include/ape" "$DEST"/*/include/ape -name '*.h' -type f -print0 2>/dev/null \
	| xargs -0 /usr/bin/sed -i '' -E -e 's|^#pragma([[:space:]]+)lib([[:space:]]+)"/[$]M/lib/|#pragma\1lib\2"|'

#
# Three headers under sys/src do the same with a path of their own:
# audio's ogg, vorbis and tags libraries are built where they sit and
# say so.  The leading slash comes off those too, and the loader finds
# them because the per-architecture mkfile and pcc both give it
# -L$ROOT/9front-src to look under.
#
find "$DEST/sys/src" -name '*.h' -type f -print0 \
	| xargs -0 /usr/bin/sed -i '' -E -e 's|^#pragma([[:space:]]+)lib([[:space:]]+)"/sys/src/|#pragma\1lib\2"sys/src/|'

#
# yacc names its parser skeleton by the path it has on a 9front
# machine.  The host build needs to say where the imported copy is,
# and cannot, because the define is unconditional.  Guarding it
# changes nothing for 9front and lets -DPARSER through here.
#
echo "letting yacc's skeleton path be overridden"
/usr/bin/sed -i '' -E \
	-e 's|^#define[[:space:]]+(PARSERS?)[[:space:]]+("/sys/lib/yaccpars?")$|#ifndef \1\'$'\n''#define \1 \2\'$'\n''#endif|' \
	"$DEST/sys/src/cmd/yacc.c"

echo "removing cpp's unused getopt declaration"
/usr/bin/sed -i '' \
	-e '/^extern	int getopt(int, char \*\*, char \*);$/d' \
	-e '/^extern	char	\*optarg;$/d' \
	-e '/^extern	int	optind;$/d' \
	"$DEST/sys/src/cmd/cpp/nlist.c"

#
# mklatin builds kbdfs's latin1.h out of lib/keyboard.  Its trie nodes
# hold the key sequence in a three-byte field -- MAXLD+1, and kbdfs
# assumes MAXLD is 2 -- and it fills that field with strcpy of the
# whole sequence before truncating it, so a three-character sequence
# writes four bytes into three.  lib/keyboard has eighty of those
# ("-*l", "DvZ", "_\"U" and the rest), and on 9front the fourth byte
# lands in the padding before the next field and nothing shows.  Built
# here it is __strcpy_chk that sees it, and the tool dies on SIGTRAP
# with nothing printed at all.
#
# Copy only the prefix the node is for -- which is what the line after
# it truncates to anyway -- and say out loud that it fits.  The assert
# is the part that matters: it is what a lib/keyboard with a
# four-character sequence would hit, instead of the corruption.
#
#
# jpg's two table generators run here and both call cmap2rgb, which
# lives in libdraw.  There is no libdraw for this machine and no
# reason to build one: cmap2rgb and the rgb2cmap beside it are
# arithmetic over the Plan 9 colour map and depend on nothing else in
# the library.  So the one file that holds them is compiled beside
# each generator.  Upstream does not need this because on a 9front
# machine the host compiler is the target compiler and -ldraw is
# there to be linked.
#
echo "giving jpg's table generators cmap2rgb"
/usr/bin/sed -i '' -E \
	-e 's%^(\t*)[$]c\^c (rgbycc|rgbrgbv)\.c$%\1$c^c \2.c\'$'\n''\1$c^c $ROOT/9front-src/sys/src/libdraw/rgb.c%' \
	-e 's%^(\t*)[$]c\^l -o [$]c\.(rgbycc|rgbrgbv) (rgbycc|rgbrgbv)\.[$]c$%\1$c^l -o $c.\2 \3.$c rgb.$c%' \
	"$DEST/sys/src/cmd/jpg/mkfile"

echo "bounding mklatin's key-sequence copy"
/usr/bin/sed -i '' \
	-e 's|^\(\t*\)strcpy((\*tp)->seq, seq);$|\1assert(q+1-(uchar*)seq <= MAXLD);\'$'\n''\1memmove((*tp)->seq, seq, q+1-(uchar*)seq);|' \
	"$DEST/sys/src/cmd/aux/kbdfs/mklatin.c"

echo "fixing host-tool main() signatures"
for f in "$DEST/sys/src/libc/ucd/mkrunetype.c"; do
	[ -f "$f" ] || continue
	/usr/bin/sed -i '' -e 's|^main(int, char)$|main(int argc, char **argv)|' \
		-e 's|"/lib/ucd/|"../../../../lib/ucd/|g' \
		-e 's|r1 = mydecomp\[x\]>>16|r1 = (uint)mydecomp[x]>>16|' "$f"
done

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
# A script the build runs starts "#!/bin/rc" or "#!/bin/awk -f",
# which is where those are on a 9front machine and not where they are
# here.  Only the ones a mkfile actually executes are changed, and
# they are found by looking: a recipe line that runs "./something" in
# the directory it is in.  That leaves alone the hundred-odd rc
# scripts under sys/src that are installed rather than run -- awk's
# tests, the auth commands -- whose first line has to stay what a
# 9front machine will read.
#
# rc goes to /usr/bin/env, so it finds the shim in 9front-glue/bin
# rather than a plan9port rc straight; awk goes to where the host
# keeps its own.
#
echo "pointing the scripts the build runs at this machine's shells"
find "$DEST" -name mkfile -type f | while read -r mf; do
	d=$(dirname "$mf")
	/usr/bin/sed -n 's|.*\./\([A-Za-z0-9_][A-Za-z0-9_.-]*\).*|\1|p' "$mf" | sort -u |
	while read -r prog; do
		f=$d/$prog
		[ -f "$f" ] || continue
		case $(head -1 "$f") in
		'#!/bin/rc'*)	/usr/bin/sed -i '' -e '1s|^#!/bin/rc|#!/usr/bin/env rc|' "$f"
				# and the paths in it, which are the same
				# paths the mkfiles name
				rewrite1 "$f"
				rewrite2 "$f";;
		'#!/bin/awk'*)	/usr/bin/sed -i '' -e '1s|^#!/bin/awk|#!/usr/bin/awk|' "$f";;
		esac
	done
done

cat > "$DEST/.gitignore" <<'EOF'
# written by scripts/import-9front.sh; see the note there

# mkone and mkmany link the program as $O.name in the directory it is
# built in and leave it there after installing it, so a build dirties
# the imported tree.  $O is a single character -- 6 for amd64, 8 for
# 386, and so on down the list in the arch mkfiles -- which means the
# pattern also matches upstream source: libmach/6.c, cmd/6c/6.out.h.
# The negations put those back.  A host tool built by 9front-glue's
# hostcc is named for $cputype, which the build sets to "host".
[01256789kquvo].*
![01256789kquvo].c
![01256789kquvo].h
![01256789kquvo].out.h
*.host

# generated into the source tree by a build of sys/src/cmd: yacc and
# lex output, the tables a program builds from its own data, and the
# scripts a mkfile writes.  The list is what "git status" showed
# after a full build; the check at the end of the import is what
# keeps it from swallowing an upstream file that later takes one of
# these names.
sys/src/cmd/bc.c
sys/src/cmd/bc.tab.h
sys/src/cmd/mpc.c
sys/src/cmd/mpc.tab.h
sys/src/cmd/pc.c
sys/src/cmd/pc.tab.h
sys/src/cmd/units.c
sys/src/cmd/units.tab.h
sys/src/cmd/awk/awkgram.c
sys/src/cmd/awk/proctab.c
sys/src/cmd/grap/grap.c
sys/src/cmd/grap/grapl.c
sys/src/cmd/pic/picy.c
sys/src/cmd/pic/picl.c
sys/src/cmd/upas/smtp/rfc822.tab.c
sys/src/cmd/upas/smtp/rfc822.tab.h
sys/src/cmd/upas/smtp/smtpd.tab.c
sys/src/cmd/ip/snoopy/protos.c
sys/src/cmd/ip/snoopy/protos.h
sys/src/cmd/jpg/ycbcr.h
sys/src/cmd/jpg/rgbv.h
sys/src/cmd/syscall/tab.h
sys/src/cmd/tcs/alias.h
sys/src/cmd/postscript/cropmarks/cropmarks
sys/src/cmd/postscript/grabit/grabit
sys/src/cmd/postscript/hardcopy/hardcopy
sys/src/cmd/postscript/printfont/printfont
sys/src/cmd/postscript/psencoding/psencoding
sys/src/cmd/postscript/mpictures/tmac.pictures
sys/src/ape/lib/ap/syscall/gencall
sys/src/libc/ucd/runebreakdata
sys/src/libc/ucd/runeistypedata
sys/src/libc/ucd/runenormdata
sys/src/libc/ucd/runetotypedata
sys/src/libsec/port/jacobian.c
sys/src/libsec/port/secp256k1.c
sys/src/libsec/port/secp256r1.c
sys/src/libsec/port/secp384r1.c

# the instruction-name table each compiler and loader builds from its
# own header with mkenam
enam.c
cnam.c
# except where upstream ships one; these two loaders do
!sys/src/cmd/9l/cnam.c
!sys/src/cmd/ql/cnam.c

# a tool built to run on the build machine, named for $cputype, which
# this build sets to "host"
host.*

# a library that a mkfile builds beside its sources rather than
# installing, named for the object character the same way
*.a[01256789kquv]

# source a mkfile generates into the directory it is built in, from
# data the import brings across for exactly this
sys/src/cmd/aux/kbdfs/latin1.h
sys/src/cmd/nusb/disk/scsierrs.c

# The tree-wide .gitignore treats a one-letter suffix as compiler
# output and *.patch as a patch someone left lying about.  Under two
# of 9front's test directories they are neither -- they are the input
# and the expected output of the tests -- and an import that quietly
# dropped them would leave a tree that does not match upstream.
!sys/src/cmd/awk/test/*
!sys/src/cmd/test/patch/*.patch
EOF

#
# Nothing under $DEST is written by hand and nothing there is built,
# so immediately after an import every file in it came from upstream
# and none of them may be ignored.  An ignore rule that reaches too
# far -- mine above, or one added to the tree-wide .gitignore later --
# silently drops upstream files, which is how twenty of awk's test
# files went missing once.  Check rather than trust.
#
if git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1; then
	swallowed=$(git -C "$PWD" ls-files --others --ignored --exclude-standard -- 9front-src)
	if [ -n "$swallowed" ]; then
		echo "error: .gitignore swallows imported files:" >&2
		echo "$swallowed" >&2
		exit 1
	fi
fi

#
# The other direction.  Most of that .gitignore is a list of exact
# paths a build writes into the source tree, and a path that names
# nothing is either a typo or something upstream stopped generating.
# Neither is caught by the check above -- an entry that matches no
# file cannot swallow one -- and either would sit there unnoticed
# until a build put a real file at that name.  So: every entry that
# names a directory under sys/src must name a directory that exists.
#
missing=
while IFS= read -r pat; do
	case "$pat" in
	'#'*|''|'!'*|*'*'*)	continue;;
	*/*)			;;
	*)			continue;;
	esac
	d=$(dirname "$DEST/$pat")
	[ -d "$d" ] || missing="$missing $pat"
done < "$DEST/.gitignore"
if [ -n "$missing" ]; then
	echo "error: .gitignore names paths that do not exist:" >&2
	for p in $missing; do echo "	$p" >&2; done
	exit 1
fi

#
# What did not arrive.  This is a copy, and a copy can lose files
# without saying so: on a case-insensitive filesystem -- which is what
# a Mac has by default -- rc/bin/Kill and rc/bin/kill are the same
# name, and the second one written is the only one there.  git says so
# when it clones and nothing says so afterwards, which is how three of
# devpost's troff font files went missing without anyone noticing.
#
# So the import compares what it copied against what it copied from,
# and records the difference.  It is not an error: nothing can be done
# about it on this filesystem, and a build does not need those files.
# A deployed root does, and this is where someone finds out.
#
#
# The comparison is against upstream's index rather than against its
# working tree, and the names are compared rather than looked up.
# Both matter: git could not check the second of a colliding pair out
# either, so the tree copied from is missing it too; and on this
# filesystem asking whether rc/bin/Kill exists in a directory holding
# rc/bin/kill answers yes.
#
echo "checking what arrived"
lost=$(mktemp)
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
	want=$(mktemp)
	got=$(mktemp)
	# shellcheck disable=SC2086
	git -C "$SRC" ls-files -z -- $COPIED | tr '\0' '\n' \
		| grep -vE '^sys/src/(9|cmd/gs)/' | sort > "$want"
	# shellcheck disable=SC2086
	( cd "$DEST" && find $COPIED -type f -print 2>/dev/null ) | sort > "$got"
	comm -23 "$want" "$got" > "$lost"
	rm -f "$want" "$got"
else
	echo "	$SRC is not a git checkout; skipped"
fi
if [ -s "$lost" ]; then
	echo "warning: $(wc -l < "$lost" | tr -d " ") files did not arrive; see $DEST/MANIFEST"
fi

cat > "$DEST/MANIFEST" <<EOF
upstream	$UPSTREAM_URL
branch		$UPSTREAM_BRANCH
commit		$UPSTREAM_COMMIT
imported by	scripts/import-9front.sh
left out	sys/src/9, sys/src/cmd/gs, lib, sys/lib
EOF
if [ -s "$lost" ]; then
	{
	echo ""
	echo "did not arrive	$(wc -l < "$lost" | tr -d " ") files, one of each pair whose"
	echo "		names differ only in case; this filesystem"
	echo "		cannot hold both"
	sed 's/^/	/' "$lost"
	} >> "$DEST/MANIFEST"
fi
rm -f "$lost"
echo "imported $UPSTREAM_COMMIT into $DEST"
