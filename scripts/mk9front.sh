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
#	PATH		9front-src/bin first (mk -> mkrc, ar -> iar,
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

hostbin=$ROOT/$(/usr/bin/sed -n 's/^SYSHOST=\([^ 	]*\).*/\1/p' mkconfig)/$(/usr/bin/sed -n 's/^OBJTYPE=\([^ 	]*\).*/\1/p' mkconfig)/bin
PATH=$ROOT/9front-src/bin:$hostbin:$PLAN9/bin:$PATH
export PATH

# 6l finds -lc as $ccroot/$objtype/lib/libc.a; point it at the target
# tree the libraries are installed into
ccroot=$ROOT/9front
export ccroot

mkdir -p "$ROOT/9front/$objtype/lib" "$ROOT/9front/$objtype/bin"

dir=${1:-9front-src/sys/src}
shift || true
cd "$ROOT/$dir"
exec mkrc objtype="$objtype" "$@"
