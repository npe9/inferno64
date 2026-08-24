#!/bin/sh
# Ask every compiler this tree builds for three things it used to get
# wrong, and say so.
#
# A function with more variables than the optimiser can track.  A Bits is
# the compiler's set of variable numbers and bits.c works it in lanes of
# thirty-two -- b[n/32], 1L<<(n%32), 32*i+bitno, and so does every
# reg.c -- while NVAR, the count mkvar would hand out, was
# BITS*sizeof(ulong)*8.  Those are the same number where a ulong is
# thirty-two bits, which is what it is on Plan 9 whatever the machine,
# and twice it where a ulong is sixty-four.  So mkvar handed out numbers
# blsh could not address and blsh wrote past the end of a Bits on its own
# stack.  The compiler then died later and somewhere else with no
# diagnostic at all.
#
# A name and a number longer than symb, which is the fixed global the
# lexer builds a token in.  The macro processor has always clamped its
# writes into it; the lexer did not, so either of these wrote past the
# end of a global with whatever the source said, and 6c exited zero on a
# four thousand character name and wrote an object.
#
# What is wanted from all three is a diagnostic or a clean compile, and
# in no case a signal.
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

# four thousand of each, against a buffer of fifteen hundred
long=`awk 'BEGIN{s="";while(length(s)<4000)s=s "aaaaaaaaaa";print substr(s,1,4000)}'`
digits=`awk 'BEGIN{s="";while(length(s)<4000)s=s "1111111111";print substr(s,1,4000)}'`
echo "int $long;" >"$TMP/longname.c"
echo "int f(void){ return $long; }" >>"$TMP/longname.c"
echo "long g(void){ return $digits; }" >"$TMP/longnum.c"

bad=0
for cc in 0c 5c 6c 8c jc kc qc tc vc; do
	if ! command -v "$cc" >/dev/null 2>&1; then
		echo "ok   $cc is not built here"
		continue
	fi

	out=`"$cc" -o "$TMP/many.out" "$TMP/many.c" 2>&1`
	if [ $? -eq 0 ]; then
		echo "ok   $cc took a function with $N variables in it"
	else
		echo "FAIL $cc would not take a function with $N variables"
		echo "$out" | sed 's/^/     /' | head -3
		bad=1
	fi

	for t in longname longnum; do
		out=`"$cc" -o "$TMP/$t.out" "$TMP/$t.c" 2>&1`
		st=$?
		case "$out" in
		*"too large"*)
			echo "ok   $cc said $t was too large rather than running past its buffer"
			;;
		*)
			echo "FAIL $cc exited $st on $t and did not say it was too large"
			echo "$out" | sed 's/^/     /' | head -3
			bad=1
			;;
		esac
	done
done
exit $bad
