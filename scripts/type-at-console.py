#!/usr/bin/env python3
# Type a command at a booted kernel's serial console and print what it said.
#
# Nothing else in this tree can press a key.  The boot scripts drive QEMU
# with "-serial file:", which is output-only, and piping into "-serial
# mon:stdio" delivers nothing to the guest at all -- which is how
# os/inferno/pc/uarti8250.c went for the life of the board without the
# consuart->putc every other board has, and how a claim that "serial
# input never worked on pc64" came to be made here on the strength of a
# test that could not have shown it either way.
#
# QEMU's pipe chardev is what works: "-chardev pipe,id=c0,path=BASE"
# reads BASE.in and writes BASE.out, both ordinary FIFOs.
#
# usage: type-at-console.py BASE SECONDS COMMAND -- qemu-system-... args
#   BASE      prefix for the two FIFOs; they are created and reused
#   SECONDS   how long to let the kernel boot before typing
#   COMMAND   one line, sent with a newline after it
#
# Validate it against a board whose console input is known to work
# before trusting a negative result from it:
#
#   scripts/type-at-console.py /tmp/p 28 'echo PIPE-WORKS' \
#       qemu-system-aarch64 -M virt -cpu cortex-a72 -m 512 -display none \
#       -chardev pipe,id=c0,path=/tmp/p -serial chardev:c0 \
#       -kernel Inferno/aarch64/bin/ivirtarm64
#
# prints the guest's echo of the command and then PIPE-WORKS.
import os, subprocess, sys, threading, time

if len(sys.argv) < 5:
    sys.stderr.write(__doc__ or "usage: type-at-console.py BASE SECS CMD -- qemu...\n")
    raise SystemExit(2)
base, wait, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3]
# How long to leave the guest running after the command is typed.
# Fourteen seconds suits a command that prints and finishes.  It does
# not suit one that does real work: kfs reaming a 64M file system takes
# well over a minute on a loaded machine, so check-pc64-disk.sh was
# killing the guest mid-ream and reporting that nothing reached the
# disk -- a harness timeout reported as a broken write path.  An
# environment variable rather than an argument, because everything
# after argv[3] is the qemu command line.
hold = float(os.environ.get('INFERNO_CONSOLE_HOLD', '14'))
qemu = sys.argv[4:]
if qemu and qemu[0] == '--':
    qemu = qemu[1:]

for suf in ('.in', '.out'):
    p = base + suf
    if os.path.exists(p):
        os.unlink(p)
    os.mkfifo(p)

proc = subprocess.Popen(qemu, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
# O_RDWR so opening does not block waiting for the other end
fin = os.open(base + '.in', os.O_RDWR | os.O_NONBLOCK)
fout = os.open(base + '.out', os.O_RDWR | os.O_NONBLOCK)
buf = bytearray()

def reader():
    while True:
        try:
            d = os.read(fout, 4096)
            if d:
                buf.extend(d)
            else:
                time.sleep(0.05)
        except BlockingIOError:
            time.sleep(0.05)
        except OSError:
            break

threading.Thread(target=reader, daemon=True).start()

# Wait for the guest to SAY it is ready, not for a fixed number of
# seconds.  INFERNO_CONSOLE_WAITFOR names a string to look for in the
# console output; the numeric argument becomes a ceiling rather than
# the plan.  Without it the old fixed sleep is kept exactly, so no
# existing caller changes behaviour.
#
# This exists because a fixed delay is a guess about boot time, and
# boot time is not a constant: the memory-floor sweep boots the same
# kernel from 64M to 1024M, and at the bottom of that range the kernel
# takes over twice as long to reach a shell.  A 40-second wait that is
# ample at 128M types into a machine that has not finished booting at
# 76M, and the run then looks like "the kernel cannot run a command in
# 76M" when it means "the harness typed too early".  That is the third
# time in this tree a fixed timeout has been read as a property of the
# kernel; see doc/inferno-cloud-modern.ms.
waitfor = os.environ.get('INFERNO_CONSOLE_WAITFOR')
t_launch = time.time()

# INFERNO_CONSOLE_MARK names a string whose first appearance is timed
# and reported.  It exists to split a cold start in two: the guest's own
# clock cannot do it, because pc64's tick counter runs from machine
# reset and so counts the firmware as uptime -- measured, by comparing
# /dev/time at the prompt against this process's clock and finding they
# agree.  Timing the kernel's first line from outside is the only way to
# say how much of a boot was firmware.
mark = os.environ.get('INFERNO_CONSOLE_MARK')
if mark:
    mt = mark.encode()
    def watchmark():
        while True:
            if mt in bytes(buf):
                sys.stderr.write("MARK %r after %.2fs\n"
                                 % (mark, time.time() - t_launch))
                return
            time.sleep(0.02)
    threading.Thread(target=watchmark, daemon=True).start()
if waitfor:
    target = waitfor.encode()
    deadline = t_launch + wait
    while time.time() < deadline:
        if target in bytes(buf):
            # How long the guest took to say it was ready, from this
            # process's own clock.  Reported because it is the only
            # boot-time number available from outside the guest, and
            # because a caller measuring cold start needs it separated
            # from the settle and typing that follow.
            sys.stderr.write("READY after %.2fs\n" % (time.time() - t_launch))
            break
        time.sleep(0.1)
    else:
        sys.stderr.write("WAITFOR %r never appeared in %gs; typing anyway\n"
                         % (waitfor, wait))
    # Let the prompt settle: the token can be printed a moment before
    # the shell is actually reading.
    time.sleep(2)
else:
    time.sleep(wait)
sys.stderr.write("typing %r after %gs, %d bytes of boot seen\n" % (cmd, wait, len(buf)))
sys.stderr.flush()
# A character at a time, paced.
#
# Writing the whole line in one go loses characters: a kernel booted
# from this tree turned "echo" into "echl" partway through a typed
# command, which then failed as "echl: file does not exist" and looked
# like a bug in whatever was being tested.  There is no flow control on
# this line and the receiver is an 8250 with a 16-byte FIFO being
# drained by an interrupt handler, so a whole line arriving at once can
# overrun it.  A real person cannot type fast enough to do this, which
# is why it only shows up under a harness.
for ch in cmd.encode() + b'\n':
    os.write(fin, bytes([ch]))
    time.sleep(0.01)
time.sleep(hold)
proc.kill()
time.sleep(0.3)
sys.stdout.write(buf.decode('utf-8', 'replace').replace('\r', ''))
