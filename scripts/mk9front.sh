#!/usr/bin/env bash
#
# mk9front.sh -- build the 9front tree in 9front-src.
#
# Sets up the environment 9front's own mkfiles expect and then runs
# mk in the directory given (default: the whole userland).
#
#	ROOT		this tree, which every rewritten mkfile is
#			written in terms of
#	RCSHELL		the rc every recipe runs under; 9front's mkfiles
#			are rc scripts
#	PATH		9front-glue/bin first (mk -> mkrc, ar -> iar,
#			yacc -> iyacc), then this tree's compilers, then
#			a Plan 9 userland for sed, tr and the rest --
#			9front's mkfiles use Plan 9 regular expressions,
#			which a BSD or GNU sed does not understand
#
# Usage: scripts/mk9front.sh [-o objtype] [directory] [target...]
#
# See doc/9front-userland.ms.

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
export ROOT

objtype=amd64
if [ "${1:-}" = "-o" ]; then objtype=$2; shift 2; fi

: "${PLAN9:=/Users/npe/src/plan9port}"
if [ ! -x "$PLAN9/bin/rc" ]; then
	echo "mk9front: no rc at $PLAN9/bin/rc; set PLAN9 to a plan9port" >&2
	exit 1
fi
RCSHELL=$PLAN9/bin/rc
export RCSHELL PLAN9

# The shell mk runs recipes under.  9front-src/$objtype/mkfile sets
# MKSH, and every library and command mkfile includes it, so almost
# everything gets rc that way.  The boot loaders do not: they are
# freestanding and their mkfiles include nothing.  A recipe of theirs
# run under sh gets $prereq as one word with mk's list separator --
# 01, invisible -- still in it, and the loader is asked to open a file
# called "x64.6efi.6fs.6...".  So the default is set here as well,
# where it covers a mkfile that includes nothing; an mkfile that sets
# MKSH itself still wins.
MKSH=$RCSHELL
export MKSH

hostbin=$ROOT/$(/usr/bin/sed -n 's/^SYSHOST=\([^ 	]*\).*/\1/p' mkconfig)/$(/usr/bin/sed -n 's/^OBJTYPE=\([^ 	]*\).*/\1/p' mkconfig)/bin
PATH=$ROOT/9front-glue/bin:$ROOT/9front/host/bin:$hostbin:$PLAN9/bin:$PATH
export PATH

# the tools the build runs rather than installs: mpc, which libsec and
# libauthsrv generate source with.  Cheap when they are already built.
bash "$ROOT/9front-glue/host/mkhost.sh"

# 6l finds -lc as $ccroot/$objtype/lib/libc.a; point it at the target
# tree the libraries are installed into
ccroot=$ROOT/9front
export ccroot

# the architecture the build machine runs.  A mkfile that needs a tool
# to run here rather than on 9front says $cputype; 9front-src/host is
# the mkfile that names this machine's compiler.
cputype=host
export cputype

# the preprocessor 6c runs for -p.  A few mkfiles ask for it -- audio
# and bzip2 among them -- and what they want is an ANSI cpp, which on
# a 9front machine is /bin/cpp.  Here it is the one built above.
CPP=$ROOT/9front/host/bin/cpp
export CPP

# 9front's headers, for the same mkfiles that include nothing: on a
# 9front machine 6c finds /$objtype/include and /sys/include without
# being told, and here it has to be told.  The arch mkfile assigns
# INCLUDES rather than appending to it, so everything that includes it
# is unaffected by this.
#
# The separator is 01, not a space.  A list in a Plan 9 environment
# variable is separated by 01 -- that is the convention mk and rc
# share, and mk's readenv splits on it -- so a variable joined by
# spaces arrives as one word, and one word is one argument to the
# compiler: it would see a single -I whose directory has the other
# two -I flags inside it.  The compiler's setinclude() splits on
# spaces itself, which hides half of the mistake: the first directory
# works and the rest do not.
IWS=$'\001'
INCLUDES="-I$ROOT/9front-src/$objtype/include${IWS}-I$ROOT/9front-src/sys/include${IWS}-I$ROOT/9front-src"
export INCLUDES

mkdir -p "$ROOT/9front/$objtype/lib" "$ROOT/9front/$objtype/bin"

# A 9front machine already has /$objtype/bin/aux and its dozen
# siblings, and /sys/lib/postscript, and the rest of what an
# installation has; here the target tree starts empty and a cp into a
# directory that is not there fails.  The list is the tree's own:
# every BIN, LIB or DIR that a mkfile -- or one of the three config
# files beside a mkfile -- points at the target root.  A library
# archive is named the same way and is a file, so anything ending in
# .a is left out.
# The list is cached: working it out means reading every mkfile in the
# tree, and this script runs once per directory built.  The import
# writes 9front-src/MANIFEST last, so a cache newer than that is
# current.
dirlist=$ROOT/9front/dirs.$objtype
if [ ! -f "$dirlist" ] || [ "$ROOT/9front-src/MANIFEST" -nt "$dirlist" ]; then
	/usr/bin/grep -rhE '^[A-Z0-9_]*(BIN|LIB|DIR)=\$ROOT/9front/' "$ROOT/9front-src/sys/src" \
		--include=mkfile --include=config 2>/dev/null \
		| /usr/bin/sed -e 's/^[A-Z0-9_]*=//' -e 's/[ 	]*#.*$//' \
		| /usr/bin/tr ' \t' '\n\n' \
		| /usr/bin/grep -v '^$' \
		| /usr/bin/sed -e "s|[\$]objtype|$objtype|g" -e "s|[\$]ROOT|$ROOT|" \
			-e 's|/[^/]*\.a$||' \
		| /usr/bin/grep "^$ROOT/9front/" \
		| sort -u > "$dirlist"
fi
while read -r d; do mkdir -p "$d"; done < "$dirlist"

dir=${1:-9front-src/sys/src}
shift || true
cd "$ROOT/$dir"
exec mkrc objtype="$objtype" "$@"
