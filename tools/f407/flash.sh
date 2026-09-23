#!/bin/sh
#
# Put a kernel on the board, without anyone touching it.
#
# mikroe-uhb looks for the bootloader once and exits, so a flash and a
# reset have to be simultaneous -- which meant a hand on the button and
# a hand on the keyboard, and every mistimed attempt looked like a
# failed flash: it prints nothing and exits zero when it finds no
# device.  Looping means the reset can happen whenever, from the button
# or from ^R^R at the console (see os/inferno/port/devuart.c), and the
# whole cycle needs no hands at all.
#
#	flash.sh ~/src/mikroe-uhb ~/venv istm32f407.hex
#
# UHB is a checkout of github.com/thotypous/mikroe-uhb with
# tools/mikroe-uhb-patches applied; VENV is a python with pyusb in it.
#
UHB=${1:?usage: flash.sh <mikroe-uhb dir> <python> <file.hex>}
PY=${2:?}
HEX=${3:?}
i=0
while [ $i -lt 300 ]; do
	out=$(cd "$UHB" && "$PY" ./mikroe-uhb "$HEX" 2>&1)
	case "$out" in
	*McuType*)
		echo "$out"
		echo "FLASHED after $i tries"
		exit 0
		;;
	esac
	i=$((i+1))
	sleep 1
done
echo "no bootloader seen in $i tries; reset the board while this runs"
exit 1
