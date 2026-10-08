#!/bin/sh
# The parallel VM crossed with the JIT, on pc64, as a two-by-two.
#
# The arm64 half of this matrix -- scripts/check-arm64-jitmatrix.sh --
# has a real generator now and all four of its cells reach a shell.  This
# is the other architecture, and the one where the generator is the thing
# that does not work: comp-amd64.c is two thousand lines, has been there
# the whole time, and faults during init.
#
# disinit() says of the two options together: "do not read this as
# '*parallelvm=0 gets you the JIT'.  On pc64 it does not: '*cflag=1
# *parallelvm=0' panics with 'invalid opcode' during init, with the VM
# lock held and no second executor anywhere, so the amd64 generator is
# broken on its own account and before any of this."  That sentence was a
# measurement somebody made once.  This is the measurement, kept, and it
# agreed: two boots of that cell gave "invalid opcode" twice.
#
# WHAT THE INVALID OPCODE WAS, since it is now something else.  genw() and
# modrm() wrote a four-byte x86 field and then advanced by IBY2WD, the Dis
# word size, which is eight on a 64-bit kernel.  So every immediate,
# displacement and branch offset was followed by four bytes nobody wrote:
# llvm-objdump on a dump of the first module's code reads "movl
# $0xa61f48,%ebx" and then "addb %al,(%rax)" twice, over and over.  With
# the stride fixed the module is 15104 bytes rather than 27792, decodes as
# x86 throughout, and this cell panics with a page fault instead, which is
# the generator's remaining and much larger problem: it stores 32-bit
# halves of 64-bit Dis registers, so a field's top half keeps whatever was
# there before.  The expectation below is still PANIC and the reason has
# changed; that is worth saying rather than leaving the header describing
# a fault the script no longer sees.
#
# Two processors, because parallelvm with one is not parallel.  The
# control arm (0,0) is the point: it says what this kernel's ordinary
# failure rate is, without which a fault in another cell could be the
# host, the merge or the hardware.
#
# WHAT A PASS IS, AND WHY IT IS NOT "interactive sh".
#
# The first version of this script judged every cell on reaching an
# interactive shell, and the kernel it boots cannot reach one: this is
# CONF=pc64dev, whose init is os/inferno/init/pc64devinit.b, and that
# prints "DEVTEST: done" and then sleeps for ever on purpose.  So the
# control cell reported no-shell on a kernel that had booted and finished
# its work, and the whole matrix could only ever fail.  It is the usual
# lesson in the usual shape -- the control was broken and the reading was
# taken as a fact about the platform, which is how "pc64 does not boot
# here" got believed for an afternoon.  Either marker counts now, and the
# devtest one is named so the next reader does not have to find this out.
#
# usage: scripts/check-pc64-jitmatrix.sh [runs-per-cell]
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
RUNS=${1:-3}
BOOTSECS=${BOOTSECS:-110}
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/pc64/ipc64dev
[ -f "$KERN" ] || { echo "no $KERN; mk CONF=pc64dev first" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "no qemu-system-x86_64" >&2; exit 1; }

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0
echo "kernel `ls -l \"$KERN\" | awk '{print $5}'` bytes, `date`"

verdict() {	# verdict <log>
	if grep -aq 'no code generator' "$1"; then
		echo "nojit"
	elif grep -aq 'JIT disabled' "$1"; then
		echo "refused"
	elif grep -aqi 'panic' "$1"; then
		echo "PANIC[`grep -ai panic \"$1\" | head -1 | tr -d '\r' | sed 's/.*panic: *//' | cut -c1-40`]"
	elif grep -aq 'interactive sh' "$1" || grep -aq 'DEVTEST: done' "$1"; then
		if grep -aq 'conf .*jit 1' "$1"; then echo "ok-jit"; else echo "ok"; fi
	elif [ ! -s "$1" ]; then
		echo "no-output"
	else
		echo "no-shell[`tail -1 \"$1\" | tr -d '\r' | cut -c1-30`]"
	fi
}

#
# What each cell is expected to produce, written down in advance, so that
# the one broken cell does not make the suite useless and does not get
# quietly tolerated either.  A cell that stops matching fails whichever
# direction it moved: the (0,1) entry fails if the panic goes away, which
# is the day comp-amd64.c gets fixed and these lines and the paragraph in
# doc/multicore-plan.ms both become wrong.
#
expect() {	# expect <pv> <cf>
	case "$1$2" in
	00)	echo ok;;
	10)	echo ok;;
	01)	echo PANIC;;		# comp-amd64.c: 32-bit stores of 64-bit Dis registers
	11)	echo refused;;		# jitrefsatomic=0; disinit() says so
	esac
}

fail=0
for pv in 0 1; do
	for cf in 0 1; do
		ini="*parallelvm=$pv
*cflag=$cf"
		INFERNO_KERNEL=$KERN INFERNO_INI="$ini" \
			sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/m.iso" \
			>/dev/null 2>&1 || { echo "parallelvm=$pv cflag=$cf: iso build failed"; fail=1; continue; }
		printf 'parallelvm=%s cflag=%s: ' $pv $cf
		n=0; out=""
		while [ $n -lt $RUNS ]; do
			log="$WORK/p$pv-c$cf-$n.log"
			sh "$ROOT/scripts/qemu-inferno-efi.sh" "$WORK/m.iso" "$log" \
				"$BOOTSECS" -smp 2 >/dev/null 2>&1 || true
			out="$out `verdict \"$log\"`"
			n=`expr $n + 1`
		done
		want=`expect $pv $cf`
		printf '%s\t(want %s)' "$out" "$want"
		nok=0
		for w in $out; do
			case "$w" in
			$want*)	nok=`expr $nok + 1`;;
			esac
		done
		if [ $nok -ne $RUNS ]; then
			echo "	MISMATCH: $nok of $RUNS"
			fail=1
		else
			echo ""
		fi
	done
done

if [ $fail -eq 0 ]; then
	echo "PC64JITMATRIX-OK every cell did what it was expected to;" \
	     "*cflag=1 *parallelvm=0 is expected to panic"
	exit 0
fi
echo "PC64JITMATRIX-FAIL"
exit 1
