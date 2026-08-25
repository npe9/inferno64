#!/bin/sh
# Boot the pc64 ipc64 kernel under QEMU on a pure-TCG host (no KVM/HVF).
#
# ipc64 carries a multiboot header (magic 0x1BADB002 at file offset 72),
# so QEMU's own '-kernel' loader can hand it straight to the guest with
# no BIOS/PXE dance and no separate boot loader.  This is the invocation
# that reaches "Inferno release built at ..."; it was lost across a
# context compaction once already and cost a long reconstruction, hence
# this script.  See doc/inferno-ports.ms for the pc64 boot log findings.
#
# Two console gotchas that cost the most time re-deriving this:
#   - '-serial mon:stdio -display none' emits NOTHING for this kernel.
#     Only '-nographic' (which multiplexes the emulated VGA text console
#     onto stdio) shows any boot output at all.
#   - '-boot n' forces iPXE's own DHCP/TFTP negotiation, which is a
#     different (working, but far noisier and slower to observe) boot
#     chain than '-kernel' -- don't mix the two up when comparing logs.
#
# TCG is slow: reaching a shell prompt from a cold boot takes minutes of
# real wall-clock time, not seconds.  '-no-reboot' turns a triple fault
# into a stopped guest instead of a silent reboot loop, so a hang and a
# crash are distinguishable.
#
# Usage: ./qemu-boot.sh [extra qemu args...] | tee /tmp/pc64boot.out

exec qemu-system-x86_64 -m 512 -kernel ipc64 \
	-netdev user,id=net0 -device virtio-net,netdev=net0 \
	-nographic -no-reboot "$@"
