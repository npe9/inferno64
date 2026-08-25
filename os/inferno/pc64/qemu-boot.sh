#!/bin/sh
# Boot the pc64 ipc64 kernel under QEMU on a pure-TCG host (no KVM/HVF).
#
# ipc64 carries a multiboot header (magic 0x1BADB002 at file offset 72),
# so QEMU's own '-kernel' loader can hand it straight to the guest with
# no separate boot loader.  SeaBIOS still runs first and still prints
# its banner and (with a NIC present) iPXE's -- that is normal; the
# multiboot jump happens right after, with no further BIOS/PXE activity.
# This was lost across a context compaction once already and cost a
# long reconstruction, hence this script.  See doc/inferno-ports.ms for
# the pc64 boot log findings.
#
# '-append console=0' is not optional.  Without it the kernel's own
# "Boot configuration" dump never gets a console= entry at all (there is
# no plan9.ini under -kernel; the multiboot cmdline is the only place a
# boot argument can come from), and pc64 links both a VGA console
# (screen.6/vgasoft.6/cga.6) and a serial one (uarti8250.6).  With no
# console= argument the guest chose one silently, wrote everything to
# it, and QEMU's '-nographic' -- which mirrors COM1, not VGA text -- had
# nothing to show: SeaBIOS's own banner (which does go over the wire)
# printed fine, the guest sat at ~100% CPU actually running, and no
# kernel output ever appeared.  That looked exactly like a hang or a
# wrong boot chain and cost most of a session to tell apart from either.
#
# Three more console gotchas that cost real time re-deriving this:
#   - '-serial mon:stdio -display none' emits NOTHING for this kernel.
#     Only '-nographic' shows any boot output at all.
#   - '-boot n' forces iPXE's own DHCP/TFTP negotiation, which also
#     works but is a different, far noisier and slower chain than the
#     multiboot jump '-kernel' takes -- don't mix the two up when
#     comparing logs.
#   - dropping the NIC (-nic none) is not a shortcut: it still reaches
#     the same silent-VGA-console stall, since the missing console=
#     argument is what actually matters, not the NIC.
#
# TCG is slow: a cold boot to the mount step below takes the better part
# of a minute of real wall-clock time, not seconds.  '-no-reboot' turns a
# triple fault into a stopped guest instead of a silent reboot loop, so a
# hang and a crash are distinguishable.
#
# 'console=0' is OUTPUT only.  os/inferno/port/devuart.c's uartinit wires
# a console uart's output queue to serialoq (the kernel print() target)
# but never assigns a matching input queue; keyboard input still comes
# only from devkbd.  So feeding bytes into this invocation's stdin (a
# fifo, a pipe, anything) cannot deliver a keystroke to the guest no
# matter how alive the guest is -- an apparently silent shell proves
# nothing about whether it's waiting for input.  Confirmed the hard way:
# an echoed test command never came back across a live-pipe boot, before
# this was traced to the source and understood as a harness limit rather
# than evidence about the guest.
#
# Usage: ./qemu-boot.sh [extra qemu args...] | tee /tmp/pc64boot.out

exec qemu-system-x86_64 -m 512 -kernel ipc64 -append 'console=0' \
	-netdev user,id=net0 -device virtio-net,netdev=net0 \
	-nographic -no-reboot "$@"
