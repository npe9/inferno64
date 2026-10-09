#!/bin/sh
#
# The whole of doc/qpu-plan.ms's hypothesis battery, as one board run.
#
#	sh tools/jtag/qpubattery.sh            # via the RCMD poller
#
# Each line is a separate question and they are ordered so that a
# failure early makes the later ones meaningful rather than wasted:
# the POSITIVE CONTROL first, because if a tag known to work does not
# answer then nothing after it means anything.
#
# Needs a kernel with #Q (rio-pi-tk) and `bind -a '#Q' /dev'.
#
# WHAT EACH LINE DECIDES
#
# control    GET_CLOCK_RATE. An answered tag looks like
#            `tag 0x80000008 PROCESSED wrote 8 bytes'. If this is
#            UNTOUCHED the board is not answering anything and every
#            line below is noise.
#
# H4         An absent tag, for the SHAPE of that failure. If
#            EXECUTE_QPU fails the same way an absent tag does, it is
#            probably absent; if differently, it is present and
#            something else is wrong.
#
# H1         A thirty second wait. ~1.05s was this kernel's own spin
#            count giving up, so a reply later than that was never
#            possible to see. Any answer at all kills the silence
#            reading.
#
# H3         The V3D power domain, set then read back. Accepted is not
#            effective: a domain that reads back off after being set
#            on is an answer by itself.
#
# H2         Firmware-allocated memory, the leading hypothesis. If
#            EXECUTE_QPU answers from a locked allocation and not from
#            the kernel's own alias, the alias was the whole fault.
#
# THE QEMU BASELINE FOR EVERY LINE, dry-run, so a board result is read
# against numbers and not against what I expect:
#
#   control  tag 0x80000008 PROCESSED wrote 8 bytes   22 us  answered
#   H4       tag 0x80000000 PROCESSED wrote 0 bytes   12 us  answered
#   H1       tag 0x80000000 PROCESSED wrote 0 bytes   15 us  answered
#   H3 set   tag 0x80000000 PROCESSED wrote 0 bytes   11 us  answered
#   H3 read  tag 0x80000000 PROCESSED wrote 0 bytes   14 us  answered
#   arith    block base+8 and base+24, uniforms zero, no fault
#   H2       gpualloc REFUSED: no alias bits in the returned address
#
# The arithmetic line runs the GPU path against a known-good address
# instead of a firmware one, so it separates "this driver's offsets are
# wrong" from "the QPU cannot fetch from there". Without it a silent
# board would have two possible causes and no way to tell them apart.
# It is also what found the ARM pointer setting the alias bits instead
# of clearing them, which would have faulted the board on H2's first
# success.
#
# Two things that baseline already tells us. The control is the only
# line that writes any bytes, so "wrote N bytes" is the discriminator
# and not the processed bit. And under QEMU an ABSENT tag is
# indistinguishable from EXECUTE_QPU -- both PROCESSED, both zero bytes
# -- which is exactly why H4 is worth running on silicon, where an
# absent tag is refused outright and EXECUTE_QPU is not answered at
# all. Those are different failures and the emulator cannot show it.
#
set -e
cd "$(dirname "$0")/../.."

cat <<'CMDS'
bind -a '#Q' /dev
echo QPUBATTERY-BEGIN
echo '--- control: a tag known to answer'
echo tag 0x00030002 8 5 0 >/dev/v3dctl
cat /dev/v3dctl
echo '--- H4: the shape of an absent tag'
echo tag 0x000f0f0f 4 0 >/dev/v3dctl
cat /dev/v3dctl
echo '--- H1: thirty seconds for a reply'
echo reset >/dev/v3dctl
echo enable >/dev/v3dctl
qputry 0xdeadbeef 0xcafebabe
echo exec 1 1 0 1 1000 30000 >/dev/v3dctl
cat /dev/v3dctl
echo '--- H3: the V3D power domain, set then read'
echo tag 0x00038030 8 10 1 >/dev/v3dctl
cat /dev/v3dctl
echo tag 0x00030030 8 10 0 >/dev/v3dctl
cat /dev/v3dctl
echo '--- arithmetic check: the GPU path with a known-good address'
echo reset >/dev/v3dctl
echo gpufake >/dev/v3dctl
qputry 0x11111111 0x22222222 0x33333333 0x44444444
echo '--- H2: execute from firmware-allocated memory'
echo gpualloc 4096 >/dev/v3dctl
cat /dev/v3dctl
echo exec 1 1 0 1 1000 5000 >/dev/v3dctl
cat /dev/v3dctl
echo gpufree >/dev/v3dctl
echo QPUBATTERY-END
CMDS
