#!/bin/sh
# Boot imps2 on the AN500 FPGA image: a Cortex-M7, which has double
# precision floating point.  This is the reference bench -- fptest(1)
# passes every line here, so it is the oracle for the answers the
# Cortex-M4 bench beside it has to reproduce in software.
exec qemu-system-arm -M mps2-an500 -m 16 -nographic -kernel imps2 "$@"
