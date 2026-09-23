#!/bin/sh
#
# Put a kernel on the board, without anyone touching it.
#
# Start this, then reset the board whenever -- from the Reset button or
# from ^R^R at the console (see os/inferno/port/devuart.c).  The client
# waits for the bootloader to appear and programs it when it does.
#
#	flash.sh ~/src/mikroe-uhb ~/src/mikroe-uhb/venv/bin/python istm32f407.hex
#
# UHB is a checkout of github.com/thotypous/mikroe-uhb with
# tools/mikroe-uhb-patches applied; PY is a python with hidapi in it.
# See tools/mikroe-uhb-patches/README for building both.
#
# This used to wrap a loop of 300 tries around the client, on the
# belief that mikroe-uhb "looks for the bootloader once and exits".  It
# does not.  open_dev() in its hid/generic.py is
#
#	while True:
#		try:    h.open(vendor, product); break
#		except IOError: pass
#		time.sleep(RETRY_INTERVAL)
#
# so it waits by itself, and the loop was not merely redundant -- it was
# why flashing kept failing.  Each iteration had to be bounded, so every
# two minutes it killed a client that was waiting correctly and started
# another; a Reset pressed during the gap closed its five-second window
# with nothing listening.  And it judged success by grepping the output
# for "McuType", which the client prints only under -v, which the loop
# did not pass -- so on the runs where it did flash the board it
# finished by reporting "no bootloader seen in 300 tries".
#
# -v is here for that reason and not for the noise: without it a
# successful flash says nothing at all, and a silent success and a
# silent failure are the same thing to whatever is reading this.
#
UHB=${1:?usage: flash.sh <mikroe-uhb dir> <python> <file.hex>}
PY=${2:?}
HEX=${3:?}

case "$HEX" in
/*)	;;
*)	HEX=$(pwd)/$HEX ;;
esac

cd "$UHB" || exit 1
exec "$PY" ./mikroe-uhb -v "$HEX"
