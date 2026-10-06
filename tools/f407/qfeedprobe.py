#!/usr/bin/env python3
"""Type the sequence that hung a board, paced, and say whether it lived.

    qfeedprobe.py [kernel]

The hang had no console behind it: a kernel that faults in a device
write loses whatever it was printing (the console FIFO drops it) and
stops taking the receive interrupt, so even the two control-Rs that
normally drop the board into its bootloader do nothing.  A physical
reset is then the only way back, and nobody is necessarily there to
press it.  So the sequence is run under QEMU, where a hang costs a
process.
"""
import subprocess, sys, select, time

KERNEL = sys.argv[1] if len(sys.argv) > 1 else \
    "os/inferno/stm32f407/istm32f407"
CHARDELAY = 0.01
LINES = [
    "echo timescale 1 >'#P/orbit.ctl'",
    "echo still >'#P/imu.ctl'",
    "echo 200 0 0 >'#P/torque'",
    "echo phase 0 >'#P/orbit.ctl'",
    "cat '#P/orbit'",
    "cat '#P/imu.ctl'",
    "echo PROBE-ALIVE",
]

p = subprocess.Popen(["qemu-system-arm", "-M", "netduinoplus2",
                      "-nographic", "-serial", "null",
                      "-serial", "mon:stdio", "-kernel", KERNEL],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, bufsize=0)
out = ""


def drain(secs):
    global out
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.05)
        if r:
            d = p.stdout.read(4096)
            if d:
                out += d.decode("utf-8", "replace")


try:
    drain(10.0)
    for ln in LINES:
        # One character at a time: the receive register is one byte
        # deep and the echo is done from the interrupt handler, so a
        # line written in one go arrives as a DIFFERENT line.  Three
        # runs of this blamed a kernel hang on a command that had
        # never arrived whole.
        for ch in (ln + "\n").encode():
            p.stdin.write(bytes([ch]))
            p.stdin.flush()
            time.sleep(CHARDELAY)
        drain(2.0)
finally:
    p.terminate()
    p.wait()
out = out.replace("\r", "")
if "fatal" in out or "HardFault" in out:
    print("PROBE-FAULTED the kernel took an exception:")
    print("\n".join(l for l in out.splitlines() if "R1" in l or
                    "fatal" in l)[:400])
    sys.exit(1)
if "PROBE-ALIVE" not in out.split("echo PROBE-ALIVE")[-1]:
    print("PROBE-DEAD the board echoed the last command and never "
          "answered it; its tail was:")
    print("\n".join(out.splitlines()[-8:]))
    sys.exit(1)
print("PROBE-ALIVE the board ran the whole sequence and answered after it")
