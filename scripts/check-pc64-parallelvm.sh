#!/bin/sh
# Does the parallel Dis VM work on pc64?
#
# The merge that brought multicore's VM here left "*parallelvm=0", the
# tested configuration: at 0 the VM lock is taken as before and one
# interpreter runs at a time.  At 1 the lock goes and the collector
# stops the world instead, so two processors can be inside xec() at
# once.  main.c reads the option at boot, so both arms come from one
# kernel and one ISO recipe -- nothing is rebuilt between them.
#
# The control arm is the point.  parallelvm=0 on the same two-processor
# machine says what this kernel's ordinary failure rate is right now;
# without it a fault at parallelvm=1 could be the merge, the hardware,
# or the load on the host, and the number would mean nothing.  This is
# the same shape as check-pc64-smp.sh's *ncpu=1 arm, and for the same
# reason: that hunt spent days on a fault that turned out to need a
# second processor to appear at all.
#
# A clean sweep is weak evidence and the summary says so.  multicore
# reports its own failure at roughly one boot in ten, so six runs that
# all pass are consistent with a rate that would still bite.
#
# usage: scripts/check-pc64-parallelvm.sh [runs]
# needs: a built os/inferno/pc64/ipc64dev and .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
RUNS=${1:-10}
# Seconds each boot is given.  Not a detail: parallelvm=1 does more
# work per boot, and at 45s a slower boot that would have finished
# counts as a failure -- the first run of this script reported 8 of 10
# "did not finish" that way while six hand-run boots finished 4 times.
# Long enough that the control finishes with room to spare, and the
# summary prints both arms so a difference in *rate* is visible rather
# than inferred.
BOOTSECS=${BOOTSECS:-110}
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/pc64/ipc64dev
[ -f "$KERN" ] || { echo "check-pc64-parallelvm: no $KERN; mk CONF=pc64dev first" >&2; exit 1; }

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

INFERNO_KERNEL=$KERN INFERNO_INI='*parallelvm=1' \
	sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/par.iso" >/dev/null 2>&1
INFERNO_KERNEL=$KERN INFERNO_INI='*parallelvm=0' \
	sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/seq.iso" >/dev/null 2>&1

# "finished the boot" as well as "did not panic": a kernel that wedges
# silently is a failure too, and at parallelvm=1 a lost wakeup or a
# collector that never restarts the world looks exactly like that.
#
# The token is pc64dev's own last line, "DEVTEST: done".  The first
# version of this script looked for "bound #S", which ipc64 prints and
# ipc64dev does not -- so both arms reported 10 of 10 not reaching it
# and the run was inconclusive.  That is what the control arm is for:
# an instrument that fails identically on both sides is measuring
# itself.  Check the token against a known-good boot before trusting a
# count taken with it.
DONE='DEVTEST: done'
# Two signals, because one of them does not depend on timing.
# "did not finish" is a rate and moves with host load.  dis.c's own
# consistency check -- "runq: N linked + M global but K in Pready --
# the counts disagree" -- fires on a boot that completes as readily as
# on one that does not, so it separates the arms without any judgement
# about how long a boot should take.
bad=0; badhang=0; badcnt=0
ctl=0; ctlhang=0; ctlcnt=0
i=1
while [ $i -le $RUNS ]; do
	sh "$ROOT/scripts/qemu-inferno-efi.sh" "$WORK/par.iso" "$WORK/par$i.log" "$BOOTSECS" -smp 2 >/dev/null 2>&1
	if grep -q 'panic:\|illegal dis instruction\|registers for' "$WORK/par$i.log"; then
		bad=`expr $bad + 1`
	elif ! grep -q "$DONE" "$WORK/par$i.log"; then
		badhang=`expr $badhang + 1`
	fi
	if grep -q 'counts disagree' "$WORK/par$i.log"; then
		badcnt=`expr $badcnt + 1`
	fi
	sh "$ROOT/scripts/qemu-inferno-efi.sh" "$WORK/seq.iso" "$WORK/seq$i.log" "$BOOTSECS" -smp 2 >/dev/null 2>&1
	if grep -q 'panic:\|illegal dis instruction\|registers for' "$WORK/seq$i.log"; then
		ctl=`expr $ctl + 1`
	elif ! grep -q "$DONE" "$WORK/seq$i.log"; then
		ctlhang=`expr $ctlhang + 1`
	fi
	if grep -q 'counts disagree' "$WORK/seq$i.log"; then
		ctlcnt=`expr $ctlcnt + 1`
	fi
	i=`expr $i + 1`
done

echo "-smp 2, *parallelvm=1:  $bad of $RUNS faulted, $badhang did not finish the boot, $badcnt had disagreeing runq counts"
echo "-smp 2, *parallelvm=0:  $ctl of $RUNS faulted, $ctlhang did not finish the boot, $ctlcnt had disagreeing runq counts"
if [ $ctl -gt 0 ] || [ $ctlhang -gt 0 ]; then
	echo "check-pc64-parallelvm: INCONCLUSIVE -- the parallelvm=0 control" >&2
	echo "  failed too, so nothing here is attributable to the parallel VM." >&2
	exit 1
fi
if [ $ctlcnt -gt 0 ]; then
	echo "check-pc64-parallelvm: INCONCLUSIVE -- the control's runq counts" >&2
	echo "  disagree too, so that signal says nothing about the parallel VM." >&2
	exit 1
fi
if [ $bad -gt 0 ] || [ $badhang -gt 0 ] || [ $badcnt -gt 0 ]; then
	echo "check-pc64-parallelvm: FAIL -- parallelvm=1 fails where 0 does not."
	exit 1
fi
echo "check-pc64-parallelvm: no failure at parallelvm=1 in $RUNS runs."
echo "  A clean sweep is weak evidence: multicore reports roughly one"
echo "  boot in ten, which $RUNS runs can miss."
