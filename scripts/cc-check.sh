#!/bin/sh
# Ask every compiler this tree builds for four things it used to get
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
# A local double whose exponent field is written through a pointer,
# which is how fdlibm scales a result.  The two halves of it get separate
# entries in mkvar because their offsets differ, so neither looked
# address-taken; the compiler kept the double in a register, wrote the
# memory, and returned the register.  exp and pow were wrong on every
# native kernel in this tree because of it -- exp(1) returned e/2 -- and
# it is fixed in the two compilers that have a board here.  See
# fptest(1).
#
# What is wanted from the first three is a diagnostic or a clean compile,
# and in no case a signal; from the last, a store.
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

# and a set of decimal constants against the double nearest each of
# them.  mpatof took the digits into an exact integer, rounded that to a
# double, built five to the power of the digits after the point, rounded
# that to a double, and divided -- three roundings where one is wanted --
# so better than a fifth of decimal literals came out one unit in the
# last place from the nearest double: eighty-six of four hundred random
# ones, and two of the six coefficients libkern's exp carries.  The
# twelve below are ones it got wrong, with the bytes of the right answer
# beside them, worked out where correct rounding was not in question.
cat >"$TMP/fp.c" <<'FPEOF'
double v[] = {
	.26018159083016613186e-33,
	.59797114710497465075e-19,
	.28907866661760313721e3,
	.38885393363387500474e-16,
	.5167612220297299752882001e27,
	.2731672326865635515e-38,
	.4620168493407224704558530e-1,
	.2086828890931002516780083e22,
	.98415377602077642e13,
	.0410423468535606883e-30,
	.679247082276544e-8,
	.760926030926002675e-26,
};
FPEOF
fpbits="ed3a2752739df538 abad226a24a6f13b 475eed3742117240 7dcc57a0786a863c f32aaa1f47b77a45 5ab34b83cabeed37 1bb69f4bbfa7a73f 33bdf36224485c44 879f77b9d2e6a142 1a5fcd5d54a36a39 84b10f91662c3d3e 6f443213f1d6823a"

# A double the compiler is asked to keep in memory because something
# else writes half of it.  The store of the sum is what has to be there:
# without it the function returns the value it computed before the
# exponent was changed.
cat >"$TMP/overlap.c" <<'OVEOF'
typedef union {
	double	d;
	struct {
		unsigned long	lo;
		unsigned long	hi;
	} w;
} Cheat;

double
scale(double a, double b, int k)
{
	double y;

	y = a + b;
	((Cheat*)&y)->w.hi += (k<<20);
	return y;
}
OVEOF

# which compilers have had the fix; the rest have no board here to say
# whether it worked, so they are reported and not counted against
fixed=" jc tc "

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

	# the object holds each constant as eight bytes; a machine that
	# puts them the other way round is as right, so both orders count
	if "$cc" -o "$TMP/fp.out" "$TMP/fp.c" >/dev/null 2>&1; then
		hex=`od -A n -v -t x1 <"$TMP/fp.out" | tr -d ' \012'`
		miss=0
		for b in $fpbits; do
			rev=`echo $b | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/'`
			case "$hex" in
			*$b*) ;;
			*$rev*) ;;
			*) miss=`expr $miss + 1`;;
			esac
		done
		if [ $miss -eq 0 ]; then
			echo "ok   $cc put every constant at the double nearest it"
		else
			echo "FAIL $cc had $miss constants that were not the nearest double"
			bad=1
		fi
	else
		echo "FAIL $cc would not compile the constants"
		bad=1
	fi

	# The assembly names the local twice: once as the double it is and
	# once as the half being written.  A compiler that kept it in a
	# register emits no store of the whole thing, so count how many
	# times the eight-byte move mentions it.
	if "$cc" -S "$TMP/overlap.c" >"$TMP/overlap.s" 2>/dev/null; then
		st=`grep -c '	MOVD	F[0-9]*,y' "$TMP/overlap.s"`
		case "$fixed" in
		*" $cc "*)
			if [ "$st" -ge 1 ]; then
				echo "ok   $cc kept a double in memory when half of it was written"
			else
				echo "FAIL $cc left a double in a register while writing half of it"
				bad=1
			fi
			;;
		*)
			if [ "$st" -ge 1 ]; then
				echo "ok   $cc kept a double in memory when half of it was written"
			else
				echo "note $cc leaves a double in a register while writing half of it;"
				echo "     the same fix as jc and tc applies, and no board here builds with it"
			fi
			;;
		esac
	else
		echo "FAIL $cc would not compile the overlap case"
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
