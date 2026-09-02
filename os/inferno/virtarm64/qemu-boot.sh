#!/bin/sh
# Boot the virtarm64 ivirtarm64 kernel under QEMU's -M virt, cortex-a72.
#
#   export PATH=$ROOT/MacOSX/arm64/bin:$PATH
#   cd os/inferno/virtarm64 && mk INIT=virtinit install
#
# Usage: ./qemu-boot.sh [extra qemu args...] | tee /tmp/virtarm64boot.out

exec qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256 -nographic \
	-kernel ivirtarm64 -no-reboot "$@"
