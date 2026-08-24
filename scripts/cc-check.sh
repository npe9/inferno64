#!/bin/sh
# Compile a function with more variables in it than the optimiser can
# track, with every compiler this tree builds, and say so.
#
# What that used to do was kill the compiler.  A Bits is worked in lanes
# of thirty-two -- bits.c does b[n/32] and 1L<<(n%32), and so does every
# reg.c -- while NVAR, the number of variables mkvar will hand out, was
# BITS*sizeof(ulong)*8.  Those are the same number where a ulong is
# thirty-two bits and Plan 9's is; on a host where it is sixty-four they
# differ by two, so mkvar handed out variable numbers blsh could not
# address and blsh wrote past the end of the Bits it was given.  The Bits
# is on the stack, so what it wrote over was whatever the caller had,
# and the compiler died later and somewhere else with no diagnostic.
#
# Two hundred variables is past the hundred and sixty a Bits can hold,
# so what this asks for is the graceful path: the excess is not tracked,
# mkvar says so under -ww, and the function compiles.
#
# usage: scripts/cc-check.sh
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export PATH
TMP=`mktemp -d "${TMPDIR:-/tmp}/cc-check.XXXXXX"`
trap 'rm -rf "$TMP"' 0

N=200
{
	echo 'int f(int);'
	echo
	echo 'int'
	echo 'g(int a)'
	echo '{'
	echo '	int r;'
	i=0; while [ $i -lt $N ]; do echo "	int v$i;"; i=`expr $i + 1`; done
	echo
	echo '	r = 0;'
	i=0; while [ $i -lt $N ]; do echo "	v$i = f(a+$i);"; i=`expr $i + 1`; done
	i=0; while [ $i -lt $N ]; do echo "	r += v$i;"; i=`expr $i + 1`; done
	echo '	return r;'
	echo '}'
} >"$TMP/many.c"

bad=0
for cc in 0c 5c 6c 8c jc kc qc tc vc; do
	if ! command -v "$cc" >/dev/null 2>&1; then
		echo "ok   $cc is not built here"
		continue
	fi
	out=`"$cc" -o "$TMP/many.out" "$TMP/many.c" 2>&1`
	st=$?
	if [ $st -eq 0 ]; then
		echo "ok   $cc took a function with $N variables in it"
	else
		echo "FAIL $cc exited $st on a function with $N variables"
		echo "$out" | sed 's/^/     /'
		bad=1
	fi
done
exit $bad
