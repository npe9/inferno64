#!/bin/sh
# Boot the same imps2 on the AN386 FPGA image: a Cortex-M4, which has
# FPv4-SP and no double precision.  QEMU's memory map and CMSDK UART are
# identical to the AN500's, so this is the same kernel binary, not a
# second port -- the only difference the kernel can see is the FPU.
#
# What that makes this: the test bench for the software double precision
# os/inferno/nucleof303/NOTE and doc/pycubed-plan.ms want.  A console
# shell works here today, because an illegal instruction that is never
# executed never faults; fptest(1) takes a usage fault on its first
# double-precision instruction.  See doc/armv7m-ports.ms.
exec qemu-system-arm -M mps2-an386 -m 16 -nographic -kernel imps2 "$@"
