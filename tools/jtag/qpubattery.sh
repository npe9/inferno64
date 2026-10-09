#!/bin/sh
#
# doc/qpu-plan.ms's hypothesis battery, ONE QUESTION PER BOARD BOOT.
#
#	sh tools/jtag/qpubattery.sh list        # the questions and the order
#	sh tools/jtag/qpubattery.sh control     # emit one question's commands
#
# IT USED TO BE ONE RUN AND THAT WAS WRONG.  The questions were ordered
# so an early failure would make the later ones meaningful, which is the
# right instinct for independent lines and the wrong model for these:
#
#	ONE EXECUTE_QPU ATTEMPT KILLS THE PROPERTY CHANNEL FOR
#	EVERYTHING AFTER IT, PERMANENTLY, UNTIL A REBOOT.
#
# Measured on silicon, one fresh JTAG boot, the same tag before and
# after:
#
#	control GET_CLOCK_RATE   PROCESSED, 8 bytes,      25 us
#	EXECUTE_QPU              UNTOUCHED, no reply,  200004 us
#	THE SAME control again   UNTOUCHED, no reply, 1000004 us
#
# Not slower.  Not at all, at any bound, and it stays dead across
# separate board runs in the same boot.  So every line after the exec
# was reading a dead mailbox rather than its own hypothesis, and no
# REORDERING fixes that -- the exec has to be the last thing a boot
# does.
#
# It nearly produced a false finding: a later H3 came back OUT OF TIME
# and would have read as "the V3D power domain is unreadable".  The good
# H3 result -- domain 0xa state 1, answered in 23 us -- is good only
# because it ran before any exec.
#
# It also explains the wedge better than the lock did.  A dead property
# channel blocks every driver that comes back to it at runtime --
# btbcm, thermbcm here, and sdhostbcm, sdhcibcm, pwmbcm, screenbcm on
# branches that have them.  A long spinlock hold made that worse; it
# was not the cause, and a shorter bound only loses the board more
# slowly.  Capping and yielding the mailbox wait is right for the
# kernel's own sake and does NOT make an exec safe to run.
#
# EVERY QUESTION IS BRACKETED BY THE CONTROL, before and after, so each
# answer carries its own evidence that the channel was alive when the
# question was asked and whether the question killed it.  A verdict
# from an unbracketed run cannot tell its own failure from a channel
# that was already gone.
#
# Needs a kernel with #Q (rio-pi-tk).  One of these per boot, in this
# order, rebooting between:
#
#   control  GET_CLOCK_RATE alone.  If this is UNTOUCHED on a fresh
#            boot the board answers nothing and no other question can
#            be read.  Silicon: tag 0x80000008 PROCESSED, 8 bytes,
#            25 us, value 0xee6b280 = 250 MHz.
#
#   h4       An absent tag, for the SHAPE of that failure.  ANSWERED on
#            silicon, 22 us, code 0x80000001 "error parsing request",
#            buf[4] untouched -- so the firmware's tag parser ran and
#            rejected it.  EXECUTE_QPU does not look like that: neither
#            word is written and nothing comes back.  So the tag is
#            PRESENT and gets past the parser, and the handler is
#            reached and does not return.  Settled; kept because it is
#            the control that makes every other verdict mean
#            something, and because QEMU cannot show it (there both are
#            PROCESSED with zero bytes).
#
#   h3       The V3D power domain, set then read back, and the SET
#            ISSUED TWICE.  Accepted is not effective.  Silicon: domain
#            0xa reads back state 1, so the block is on and "powered
#            off" does not explain the silence.  The set is issued
#            twice because its response came back with 0 in the id slot
#            where 0xa was expected: if that is 0 both times the
#            firmware normalises it, and if only the first time our
#            buffer was read before the invalidate took -- which would
#            be a general hazard in every mboxprop response, not a
#            quirk of this tag.
#
#   enable   `enable' ALONE, with no exec, then the control again.
#            Separates "the exec poisons the channel" from "something
#            in reset/enable does".  Needed because the first poisoned
#            run showed TWO timeouts and the first had five-argument
#            shape, which means a submission happened before the
#            explicit exec.
#
#   arith    The GPU path against a known-good address instead of a
#            firmware one, so "this driver's offsets are wrong" is
#            separable from "the QPU cannot fetch from there".
#            ENDS THE BOOT: qputry writes its own `exec' to
#            /dev/v3dctl (appl/cmd/qputry.b:163), so this question is
#            an exec like h1 and h2 and poisons the channel exactly as
#            they do.  Its control-after is EXPECTED to be dead, and
#            that is the shape to look for rather than a surprise.
#            This file listed it as shareable and ordered it between
#            `enable' and h2, which would have spent a boot producing
#            a dead h2.
#
#            IT CANNOT YET TELL A CHANGED RESULT FROM AN UNCHANGED
#            ONE, and that limitation is written here rather than
#            dressed up.  qputry's positional words are QPU
#            INSTRUCTION words, written to /dev/v3dcode -- not
#            uniforms and not a result area -- so passing a sentinel
#            seeds nothing.  And devv3d's `block' line is read from
#            the block BEFORE the mailbox exchange, so it reports what
#            this driver wrote and not what the GPU produced.
#
#            What it would take: seed words the program is meant to
#            write, re-read them after the exchange with an
#            invalidate, and report the two side by side.  Until that
#            exists this line says only whether the submission was
#            accepted, which is worth running and is not an
#            arithmetic result.
#
#   h2       EXECUTE_QPU from firmware-allocated, locked memory.  The
#            leading hypothesis and now a clean single-question
#            experiment: if it answers from a firmware allocation when
#            it never answers from the kernel's own alias, the alias
#            was the whole fault.  ITS OWN BOOT, and it ends the boot.
#
#   h1       EXECUTE_QPU from the kernel's own alias, bounded.  ENDS
#            THE BOOT; nothing after it can be read.  2 s, not 30:
#            every tag that answers answers in 22-31 us, so 2 s is
#            eighty thousand times the observed latency and already
#            past the 1.05 s artefact that 30 s was chosen to beat.  A
#            30 s version needs a card boot AND a yieldable wait, and
#            is not worth it.
#
#   h5       The V3D's own IDENT0 register, read directly.  Answers
#            what the mailbox cannot: is the hardware THERE, whatever
#            the firmware says.  0x02443356 is "V3D".
#            IT CAN HANG THE BOARD -- a peripheral whose power domain
#            is off can stall the bus on this chip rather than
#            returning zero -- so it gets its own boot and is last, and
#            a run that ends here with no further output IS the answer.
#
# QEMU BASELINE, dry-run, so a board result is read against numbers:
#
#   control  tag 0x80000008 PROCESSED wrote 8 bytes   22 us  answered
#   h4       tag 0x80000000 PROCESSED wrote 0 bytes   12 us  answered
#   h1       tag 0x80000000 PROCESSED wrote 0 bytes   15 us  answered
#   h3 set   tag 0x80000000 PROCESSED wrote 0 bytes   11 us  answered
#   h3 read  tag 0x80000000 PROCESSED wrote 0 bytes   14 us  answered
#   arith    block base+8 and base+24, uniforms zero, no fault
#            (that `block' is the pre-exchange snapshot, see above)
#   h2       gpualloc REFUSED: no alias bits in the returned address
#
# QEMU FABRICATES VALUES for tags it accepts -- V3D clock 700 MHz there
# against 250 on silicon -- so a baseline says the request is
# well-formed and says NOTHING about the value.  There is no
# nonsense-VALUE control, only the nonsense-TAG one.
#
set -e
cd "$(dirname "$0")/../.."

q=${1:-}

prologue() {
	echo "bind -a '#Q' /dev"
	echo "echo QPUBATTERY-BEGIN $q"
	echo "echo '--- control BEFORE: a tag known to answer'"
	echo "echo tag 0x00030002 8 5 0 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
}

epilogue() {
	echo "echo '--- control AFTER: the same tag, to see if the question killed it'"
	echo "echo tag 0x00030002 8 5 0 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	echo "echo QPUBATTERY-END $q"
}

case "$q" in
list|"")
	cat <<'LIST'
One of these per boot, rebooting between.  Each prints its own
control before and after, so a verdict carries the evidence that the
channel was alive when the question was asked.

	control   the positive control alone, on a fresh boot
	h4        an absent tag, for the shape of that failure
	h3        the V3D power domain, set twice then read
	enable    `enable' with no exec: does IT poison the channel?
	arith     the GPU path, known-good address  -- ENDS THE BOOT
	h2        EXECUTE_QPU from firmware memory   -- ENDS THE BOOT
	h1        EXECUTE_QPU from our own alias     -- ENDS THE BOOT
	h5        the V3D IDENT0 register directly   -- CAN HANG THE BOARD

An exec kills the property channel until a reboot, so every question
that executes -- h1, h2, AND arith, because qputry issues its own exec
-- must be the last thing its boot does and no two can share one.  h5
can stall the bus, so it gets its own boot too.

ANSWERED ALREADY, on silicon, each in its own boot: control (25us, 250
MHz), h4 (an absent tag IS answered, 0x80000001, 22us), h3 (domain 0xa
reads back state 1), enable (reset and SET_ENABLE_QPU leave the channel
intact -- 25us before, 24us after).  So EXECUTE_QPU is reached, never
returns, and takes the property channel with it, and h2 is the question
that is left.
LIST
	# No argument is a usage error even though the list is useful
	# output: a caller that meant to pass a question and passed
	# nothing must not read exit 0 as "the question ran".
	if [ -z "$q" ]; then
		exit 2
	fi
	exit 0
	;;
control)
	prologue
	epilogue
	;;
h4)
	prologue
	echo "echo '--- h4: the shape of an absent tag'"
	echo "echo tag 0x000f0f0f 4 0 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	epilogue
	;;
h3)
	prologue
	echo "echo '--- h3: set the V3D power domain (first of two)'"
	echo "echo tag 0x00038030 8 10 1 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	echo "echo '--- h3: the same set again, to read the id slot twice'"
	echo "echo tag 0x00038030 8 10 1 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	echo "echo '--- h3: read it back'"
	echo "echo tag 0x00030030 8 10 0 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	epilogue
	;;
enable)
	prologue
	echo "echo '--- enable: reset and enable, NO exec'"
	echo "echo reset >/dev/v3dctl"
	echo "echo enable >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	epilogue
	;;
arith)
	prologue
	echo "echo '--- arith: the GPU path with a known-good address'"
	echo "echo reset >/dev/v3dctl"
	echo "echo gpufake >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	echo "echo '--- arith: four QPU instruction words. ENDS THE BOOT (qputry execs)'"
	echo "qputry 0x11111111 0x22222222 0x33333333 0x44444444"
	epilogue
	;;
h2)
	prologue
	echo "echo '--- h2: execute from firmware-allocated memory. ENDS THE BOOT'"
	echo "echo gpualloc 4096 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	echo "echo exec 1 1 0 1 1000 2000 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	echo "echo gpufree >/dev/v3dctl"
	epilogue
	;;
h1)
	prologue
	echo "echo '--- h1: execute from our own alias. ENDS THE BOOT'"
	echo "echo reset >/dev/v3dctl"
	echo "echo enable >/dev/v3dctl"
	echo "echo exec 1 1 0 1 1000 2000 >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	epilogue
	;;
h5)
	prologue
	echo "echo '--- h5: the V3D IDENT0 register. THIS CAN HANG THE BOARD'"
	echo "echo ident >/dev/v3dctl"
	echo "cat /dev/v3dctl"
	epilogue
	;;
*)
	echo "qpubattery: no question '$q'; try: sh $0 list" >&2
	exit 2
	;;
esac
