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
#	parallelvm=0 cflag=1	the JIT alone -- and on this architecture
#				there is no JIT: comp-aarch64.c is a
#				forty-five line stub.  The cell is a pass
#				when the kernel SAYS so, which is what
#				this is really testing.  (On pc64 the
#				generator is real and panics with
#				"invalid opcode" during init.)
#	parallelvm=1 cflag=1	with a generator, disinit() would refuse
#				this and say so:
#				the generator this board links,
#				comp-aarch64.c, sets jitrefsatomic=0, so
#				Heap.ref would be updated without
#				atomics while two executors run.  A cell
#				that reports its own refusal is a pass.
#
# Four processors, because parallelvm with one is not parallel and the
# arm of the matrix that matters would measure nothing.
#
# usage: scripts/check-arm64-jitmatrix.sh [runs-per-cell]
set -u
ROOT=`cd \`dirname "$0"\`/.. && pwd`
RUNS=${1:-3}
BOOTSECS=${BOOTSECS:-120}
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

boot() {	# boot <ini> <log>
	dd if=/dev/zero of="$WORK/vars.fd" bs=1m count=64 2>/dev/null
	INFERNO_KERNEL=$KERN INFERNO_INI="$1" \
		sh "$ROOT/scripts/mkinferno-efi-disk-arm64.sh" "$WORK/a.img" \
		>/dev/null 2>&1 || return 1
	timeout $BOOTSECS qemu-system-aarch64 -M virt -cpu cortex-a72 \
		-smp 4 -m 512 -display none -no-reboot \
		-drive if=pflash,format=raw,readonly=on,file="$FW" \
		-drive if=pflash,format=raw,file="$WORK/vars.fd" \
		-drive if=none,id=hd,format=raw,file="$WORK/a.img" \
		-device virtio-blk-device,drive=hd \
		-serial "file:$2" >/dev/null 2>&1 || true
	return 0
}

#
# What a boot is judged on.  Reaching a shell is the only thing that
# says the whole VM came up; a panic and a wedge are told apart because
# they are different bugs.
#
verdict() {	# verdict <log>
	#
	# NOT the banner.  The first version of this read "conf ... jit 1"
	# and called that cell ok-jit, which is exactly what the kernel says
	# while compiling nothing: comp-aarch64.c is forty-five lines whose
	# compile() returns 0, so there is no JIT on this architecture at
	# all.  Reading the banner measured the option, not the behaviour.
	#
	# What is read instead is what disinit() says it did with the
	# option, which is now one of three things: no generator, refused
	# for the parallel VM, or nothing to say and the JIT is on.
	#
	if grep -aq 'interactive sh' "$1"; then
		if grep -aq 'no code generator' "$1"; then
			echo "ok-nojit"
		elif grep -aq 'JIT disabled' "$1"; then
			echo "ok-refused"
		elif grep -aq '^conf .*jit 1' "$1"; then
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
*cflag=$cf"
		printf 'parallelvm=%s cflag=%s: ' $pv $cf
		n=0
		out=""
		while [ $n -lt $RUNS ]; do
			log="$WORK/p$pv-c$cf-$n.log"
			boot "$ini" "$log" || { out="$out build-failed"; break; }
			out="$out `verdict \"$log\"`"
			n=`expr $n + 1`
		done
		echo "$out"
		case "$out" in
		*panic*|*"no shell"*|*"no output"*|*build-failed*)	fail=1;;
		esac
		cp "$WORK/p$pv-c$cf-0.log" "$ROOT/tmp-jitmatrix-p$pv-c$cf.log" 2>/dev/null || true
	done
done

if [ $fail -eq 0 ]; then
	echo "JITMATRIX-OK all four cells reached a shell"
	exit 0
fi
echo "JITMATRIX-FAIL"
exit 1
