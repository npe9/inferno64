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

mkdir -p "$ROOT/9front/$objtype/lib" "$ROOT/9front/$objtype/bin"

# A 9front machine already has /$objtype/bin/aux and its dozen
# siblings; here the target tree starts empty and cp into a directory
# that is not there fails.  The list is the tree's own: every BIN a
# mkfile sets under the target root.
/usr/bin/grep -rh '^BIN=\$ROOT/9front/' "$ROOT/9front-src/sys/src" --include=mkfile 2>/dev/null \
	| /usr/bin/sed -e 's/^BIN=//' -e "s|[\$]objtype|$objtype|g" -e "s|[\$]ROOT|$ROOT|" \
	| sort -u | while read -r d; do mkdir -p "$d"; done

dir=${1:-9front-src/sys/src}
shift || true
cd "$ROOT/$dir"
exec mkrc objtype="$objtype" "$@"
