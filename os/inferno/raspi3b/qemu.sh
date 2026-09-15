#!/bin/sh
# Boot kernel8.img -- the same file the Pi firmware loads -- the way the
# firmware does: QEMU -M raspi3b treats a raw arm64 image as a Linux
# kernel, loads it at 0x80000, enters core 0 at non-secure EL2 with the
# other cores in a spin table at 0xd8, and passes the device tree in x0.
# Give it the firmware's own tree from the Pi's boot partition to match the
# card exactly:  DTB=/Volumes/bootfs/bcm2710-rpi-3-b.dtb ./qemu.sh
# Serial 0 is the PL011 console; serial 1 the mini UART.
dtb=
if [ -n "$DTB" ]; then dtb="-dtb $DTB"; fi
exec qemu-system-aarch64 -M raspi3b -m 1G -display none -monitor none \
	-serial stdio -serial null $dtb -kernel kernel8.img "$@"
