#!/bin/sh
# The parallel VM crossed with the JIT, on arm64, as a two-by-two.
#
# Both axes are boot options on virtarm64 now -- *parallelvm was one
# already and *cflag was added beside it -- so all four cells come from
# ONE kernel and one disk recipe, and nothing is rebuilt between them.
# That is the whole reason the matrix had never been run on this board:
# a two-by-two where one axis costs a relink is a two-by-two that gets
# done once and believed thereafter.
#
# What each cell is expected to do, and why saying so in advance matters:
#
#	parallelvm=0 cflag=0	the shipped configuration; the control
#	parallelvm=1 cflag=0	the parallel VM as it ships on multicore
#	parallelvm=0 cflag=1	the JIT alone.  comp-aarch64.c is a real code
#				generator now -- it was a forty-five line stub
#				when this script was written, and the version
#				of these lines that said so is what the first
#				green run of this matrix was measured against.
#	parallelvm=1 cflag=1	both.  Legitimate only because comp-aarch64.c
#				sets jitrefsatomic=1: it updates Heap.ref with
#				LDXRW/STXRW retry loops at all four sites, so
#				disinit() does not have to refuse it.  A
#				generator without that would be refused here
#				and the refusal would be the pass.
#
# All four are expected to reach a shell, and the two cflag=1 cells are
# expected to reach it as ok-jit -- with a generator present and not
# refused.  ok-nojit or ok-refused from this board now means something
# regressed, not that the architecture has no JIT.
#
# Four processors, because parallelvm with one is not parallel and the
# arm of the matrix that matters would measure nothing.
#
# usage: scripts/check-arm64-jitmatrix.sh [runs-per-cell]
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
RUNS=${1:-3}
BOOTSECS=${BOOTSECS:-180}
#
# What disbench's inner loops are repeated.  Twenty, because at one the
# JIT cells report zeros: this board's clock ticks at 10ms and the whole
# compiled run fits inside two of them, so the first version of this
# printed "int=0 loop=0 call=0" and called it a measurement.  A number
# below the clock's resolution is not a fast result, it is no result.
#
REPS=${REPS:-20}
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/virtarm64/ivirtarm64
[ -f "$KERN" ] || { echo "no $KERN; mk ivirtarm64 first" >&2; exit 1; }
#
# The firmware, found rather than remembered.  check-arm64-smp.sh wants it
# at .qemu/edk2-aarch64-code.fd and this checkout has no such file, so that
# script refuses to run here; the packaged qemu ships one.
#
FW=${FW:-$ROOT/.qemu/edk2-aarch64-code.fd}
if [ ! -f "$FW" ]; then
	for f in /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
		 /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
		 /usr/share/AAVMF/AAVMF_CODE.fd; do
		[ -f "$f" ] && { FW=$f; break; }
	done
fi
[ -f "$FW" ] || { echo "no aarch64 EFI firmware; set FW=" >&2; exit 1; }
echo "firmware $FW"
command -v qemu-system-aarch64 >/dev/null 2>&1 || { echo "no qemu-system-aarch64" >&2; exit 1; }

WORK=`mktemp -d`
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0

#
# The build stamp, recorded once, because a number attributed to the
# wrong kernel is worse than no number.
#
echo "kernel `ls -l \"$KERN\" | awk '{print $5}'` bytes, `date`"

#
# boot, and time how long the Dis half of it took.
#
# The boot does not end -- it reaches an interactive shell on the UART
# and sits there until the timeout -- so wall clock for the qemu process
# measures BOOTSECS and nothing else.  What is timed instead is the wait
# for "interactive sh" to appear in the serial log, which is the whole
# Dis boot: osinit, the init module's binds, the ACPI and disk probes,
# and the shell coming up, all of it Limbo.  The number is left in
# $MSEC.
#
# It is a coarse instrument and the point of saying so is that nobody
# reads it as a benchmark.  It includes the firmware and the kernel's own
# device probes, which the JIT cannot touch, the poll granularity is
# 100ms, and it moves with what the host is doing: the same four cells
# came back a second faster on an idle machine than on one that was
# building kernels.  It is kept because a boot that suddenly takes twice
# as long is worth seeing.
#
# THE SPEED NUMBER IS DISBENCH.  Every cell boots with *disbench=1, so
# each one runs disbench(1) out of the kernel's own root file system
# before it reaches a shell, and its per-test milliseconds are what this
# prints.  That is loops rather than one pass over each module, and each
# test carries a checksum computed outside the VM, so a JIT that is fast
# and wrong fails here rather than looking good.
#
boot() {	# boot <ini> <log>
	dd if=/dev/zero of="$WORK/vars.fd" bs=1m count=64 2>/dev/null
	INFERNO_KERNEL=$KERN INFERNO_INI="$1" \
		sh "$ROOT/scripts/mkinferno-efi-disk-arm64.sh" "$WORK/a.img" \
		>/dev/null 2>&1 || return 1
	rm -f "$2"
	start=`python3 -c 'import time;print(int(time.time()*1000))'`
	#
	# No timeout(1) around this, deliberately.  With one, $! is timeout's
	# pid and not qemu's, so the kill below would depend on timeout
	# forwarding the signal -- and if it did not, an orphaned qemu would
	# still be holding $WORK/a.img while the next cell rewrote it, which
	# is a way to manufacture a failure in the cell after the one that
	# went wrong.  The deadline is in the poll loop instead, where the
	# pid is qemu's own.
	#
	qemu-system-aarch64 -M virt -cpu cortex-a72 \
		-smp 4 -m 512 -display none -no-reboot \
		-drive if=pflash,format=raw,readonly=on,file="$FW" \
		-drive if=pflash,format=raw,file="$WORK/vars.fd" \
		-drive if=none,id=hd,format=raw,file="$WORK/a.img" \
		-device virtio-blk-device,drive=hd \
		-serial "file:$2" >/dev/null 2>&1 &
	qpid=$!
	#
	# Timed to the first DISBENCH line, not to the shell.  With
	# *disbench set the benchmark runs before the shell does, so "to
	# shell" would be the boot plus fifteen seconds of deliberate work
	# and would say nothing about either.  The first DISBENCH line is
	# printed after the same binds and probes the shell used to mark,
	# and before any of the loops.
	#
	MSEC=-1
	deadline=`expr $start + $BOOTSECS \* 1000`
	while kill -0 $qpid 2>/dev/null; do
		if grep -aq 'DISBENCH ' "$2" 2>/dev/null; then
			MSEC=`python3 -c "import time;print(int(time.time()*1000)-$start)"`
			break
		fi
		now=`python3 -c 'import time;print(int(time.time()*1000))'`
		[ "$now" -ge "$deadline" ] && break
		python3 -c 'import time;time.sleep(0.1)'
	done
	#
	# The boot is timed by then and the benchmark is not finished, so
	# wait for the shell before taking the machine away.  Without this
	# the cell reports the boot and no disbench numbers at all.
	#
	while kill -0 $qpid 2>/dev/null; do
		grep -aq 'interactive sh' "$2" 2>/dev/null && break
		now=`python3 -c 'import time;print(int(time.time()*1000))'`
		[ "$now" -ge "$deadline" ] && break
		python3 -c 'import time;time.sleep(0.2)'
	done
	kill $qpid 2>/dev/null || true
	wait $qpid 2>/dev/null || true
	return 0
}

#
# What a boot is judged on.  Reaching a shell is the only thing that
# says the whole VM came up; a panic and a wedge are told apart because
# they are different bugs.
#
verdict() {	# verdict <log>
	#
	# NOT the banner alone.  The first version of this read
	# "conf ... jit 1" and called that cell ok-jit, which was exactly
	# what the kernel said while compiling nothing: comp-aarch64.c was
	# then forty-five lines whose compile() returned 0.  Reading the
	# banner measured the option, not the behaviour.
	#
	# So what is read first is what disinit() says it DID with the
	# option -- no generator, or refused for the parallel VM -- and the
	# banner only decides between ok-jit and ok once neither of those
	# was printed.  The generator is real now, so ok-jit is the
	# expected answer and the other two are regressions; the check is
	# written this way round so it keeps working either way.
	#
	if grep -aq 'interactive sh' "$1"; then
		if grep -aq 'no code generator' "$1"; then
			echo "ok-nojit"
		elif grep -aq 'JIT disabled' "$1"; then
			echo "ok-refused"
		elif grep -aq 'conf .*jit 1' "$1"; then
			echo "ok-jit"
		else
			echo "ok"
		fi
	elif grep -aqi 'panic' "$1"; then
		echo "panic: `grep -ai panic \"$1\" | head -1 | tr -d '\r' | cut -c1-72`"
	elif [ ! -s "$1" ]; then
		echo "no output at all"
	else
		echo "no shell: `tail -1 \"$1\" | tr -d '\r' | cut -c1-60`"
	fi
}

fail=0
for pv in 0 1; do
	for cf in 0 1; do
		ini="*parallelvm=$pv
*cflag=$cf
*disbench=$REPS"
		printf 'parallelvm=%s cflag=%s: ' $pv $cf
		n=0
		out=""
		times=""
		while [ $n -lt $RUNS ]; do
			log="$WORK/p$pv-c$cf-$n.log"
			boot "$ini" "$log" || { out="$out build-failed"; break; }
			out="$out `verdict \"$log\"`"
			times="$times $MSEC"
			n=`expr $n + 1`
		done
		echo "$out	to first DISBENCH line (ms):$times"
		#
		# The benchmark, from the first boot of the cell.  Printed
		# rather than averaged: three boots of a deterministic loop
		# under TCG do not need a mean, and a reader comparing cells
		# wants the per-test numbers, not one figure of merit.
		#
		b0="$WORK/p$pv-c$cf-0.log"
		if grep -aq DISBENCH-OK "$b0"; then
			printf '	disbench (ms):'
			grep -a 'DISBENCH ' "$b0" | tr -d '\r' | \
				awk '{printf " %s=%s", $2, $4}'
			echo ""
		else
			echo "	disbench: did not finish or gave a wrong answer"
			grep -a 'DISBENCH-FAIL\|WRONG' "$b0" | tr -d '\r' | sed 's/^/	/'
			fail=1
		fi
		case "$out" in
		*panic*|*"no shell"*|*"no output"*|*build-failed*)	fail=1;;
		esac
		#
		# A cflag=1 cell that reaches a shell without the JIT is a
		# regression, not a pass.  Both ways it can happen say so on
		# the console -- disinit() prints when it drops the option --
		# and without this the matrix would go green on a kernel whose
		# generator had gone back to being a stub.
		#
		# Counted, not matched: with three runs per cell, "ok-jit ok-jit
		# ok" contains ok-jit and is still a cell that lost the JIT once.
		if [ $cf -eq 1 ]; then
			njit=0
			for w in $out; do
				[ "$w" = ok-jit ] && njit=`expr $njit + 1`
			done
			if [ $njit -ne $RUNS ]; then
				echo "	cflag=1: $njit of $RUNS boots had the JIT"
				fail=1
			fi
		fi
		cp "$WORK/p$pv-c$cf-0.log" "$ROOT/tmp-jitmatrix-p$pv-c$cf.log" 2>/dev/null || true
	done
done

if [ $fail -eq 0 ]; then
	echo "JITMATRIX-OK all four cells reached a shell, both cflag=1 cells with the JIT"
	exit 0
fi
echo "JITMATRIX-FAIL"
exit 1
