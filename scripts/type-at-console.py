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
time.sleep(wait)
sys.stderr.write("typing %r after %gs, %d bytes of boot seen\n" % (cmd, wait, len(buf)))
sys.stderr.flush()
os.write(fin, cmd.encode() + b'\n')
time.sleep(14)
proc.kill()
time.sleep(0.3)
sys.stdout.write(buf.decode('utf-8', 'replace').replace('\r', ''))
