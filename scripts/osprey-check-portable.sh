#!/bin/sh
# Compile the parts of Osprey that are meant to be portable for machines
# they have never run on, and say so.
#
# os/osprey/policy/README says the layer is "kept independent of Proc,
# Mach, device drivers, and architecture trap code", and the plan says
# the same in more words.  Nothing checked it: everything in the tree
# builds it with 6c against the amd64 headers, where an assumption about
# the width of a pointer or of a long is invisible.  This builds every
# policy source with 8c against the 386 headers -- thirty-two bit, where
# such an assumption is not invisible -- and with kc against the riscv64
# headers, which is a machine of a different family altogether.
#
# The policy layer needs only u.h, pool.h and fcall.h, which is why the
# Inferno headers for those machines will do: there is no Osprey build
# for either of them and the point is not to make one.
#
# The container-side library goes with it, for 386 only: it needs a
# libc.h, and 9front has one for 386 where Inferno has lib9.h instead
# and no riscv64 tree has either.
#
# The objects are thrown away.  What is being asked is whether the
# sources compile, not whether they would link into a kernel that does
# not exist; the two trees disagree about the width of usize, which is
# why os/osprey/lib builds against the Osprey headers and this does not.
#
# usage: scripts/osprey-check-portable.sh
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export PATH
TMP=`mktemp -d "${TMPDIR:-/tmp}/osprey-portable.XXXXXX"`
trap 'rm -rf "$TMP"' 0

bad=0
try() {			# try compiler objtype policyheaders [libraryheaders]
	cc=$1; ot=$2; inc=$3; lib=$4
	out=$TMP/$ot.log
	: >"$out"
	for f in "$ROOT"/os/osprey/policy/*.c; do
		"$cc" -wFV -I"$ROOT/os/osprey/policy" -I"$inc" -I"$ROOT/include" \
			-o "$TMP/o" "$f" >>"$out" 2>&1 || echo "FAILED $f" >>"$out"
	done
	if [ -n "$lib" ]; then
		# the machine's own headers first: Osprey/include holds a
		# libc.h of its own, and searching that first would give
		# the 386 compiler the amd64 one
		"$cc" -wFV -I"$ROOT/os/osprey/libosprey9" -I"$lib" \
			-I"$ROOT/9front/include" -I"$ROOT/Osprey/include" \
			-I"$ROOT/Osprey/include/osprey" -o "$TMP/o" \
			"$ROOT/os/osprey/libosprey9/osprey9.c" >>"$out" 2>&1 \
			|| echo "FAILED osprey9.c" >>"$out"
	fi
	if [ -s "$out" ]; then
		echo "FAIL the portable layer built for $ot"
		sed 's/^/     /' "$out"
		bad=1
	else
		if [ -n "$lib" ]; then
			echo "ok   the policy layer and the library built for $ot, warnings and all"
		else
			echo "ok   the policy layer built for $ot, warnings and all"
		fi
	fi
}

try 8c 386 "$ROOT/Inferno/386/include" "$ROOT/9front/386/include"
try kc riscv64 "$ROOT/Inferno/riscv64/include"
exit $bad
