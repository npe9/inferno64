#!/bin/sh
# Boot the armv7 iarmv7 kernel under QEMU's -M virt, cortex-a15.
#
# Build first -- INIT is not defaulted anywhere in the mkfile chain,
# it has to be passed on the command line, the same as pc64fatinit or
# virtinit elsewhere:
#
#   export PATH=$ROOT/MacOSX/arm64/bin:$PATH
#   cd os/inferno/armv7 && mk INIT=armv7minit install
#
# This board is console-only on purpose (no draw/pointer/swcursor,
# same as the spike precedent) and does not yet reach a shell: it
# boots, loads and type-checks /osinit.dis into the Dis interpreter,
# gets through the module loader into module initialization, and
# crashes right after loading Bufio, going into devprog.  See
# doc/inferno-ports.ms for the full history -- five real board bugs
# found and fixed there already (four in the trap path, one a
# /dis-vs-/dis32 root file list mismatch) -- and for what's still
# open: two independent, never-co-occurring faults at that same
# point, one of them (an Undefined instruction trap, up nil, on the
# boot-time SVC stack) fully deterministic and pinned by address
# (stack+KSTACK, 0x400f8dd0 in the build that address was captured
# against -- expect it to move a little as the binary's own size
# changes) but not yet chased to an instruction; the other (a data
# abort) genuinely varies run to run, the same heisenbug fingerprint
# already on record for pc64's own markheap() crash.
#
# Usage: ./qemu-boot.sh [extra qemu args...] | tee /tmp/armv7boot.out
#
# For batch classification of the two fault kinds across N boots (the
# repeated ad-hoc bash loop several sessions have now rebuilt by
# hand):
#
#   for i in $(seq 1 20); do
#     timeout 15 ./qemu-boot.sh -serial file:/tmp/armv7run$i.log \
#         >/dev/null 2>&1
#   done
#   grep -h "trap type" /tmp/armv7run*.log | sort | uniq -c
#
# A line reading "trap type 1 ... pc 0x...8dd0-ish" with no matching
# "up " line right after it is the deterministic fault; a "trap type
# 4" with a "up ... interp" line right after it is the varying one.

exec qemu-system-arm -M virt -cpu cortex-a15 -m 256 -nographic \
	-kernel iarmv7 -no-reboot "$@"
