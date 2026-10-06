#!/usr/bin/env python3
"""Read the simulated devices hard, at the fastest time scale, and see
whether the kernel survives it.

    simsoak.py [reads] [kernel]

WHAT THIS IS FOR.  A board hung on a write to one of these files, with
no console and no response to the two control-Rs that normally reach
the bootloader -- a kernel that faults in a device write loses the
print it was making and stops taking the receive interrupt, so the only
way back is the reset button.  The cause was never found and the image
that did it no longer exists.  What can be done is to make the build
being shipped take the same traffic, a few hundred times, under
something that costs a process rather than a person.

At timescale 200 every read integrates two hundred times as much
simulated time as the interval before it, so a soak here exercises the
step loop, the carried remainders and the quaternion renormalisation
far harder than a mission run does.  It also watches the BACKLOG: the
integrator defers what it cannot step in one call, and a backlog that
grows without bound is a model falling behind real time, which is a
fault whether or not anything crashes.
"""
import re, subprocess, sys, select, time

READS = int(sys.argv[1]) if len(sys.argv) > 1 else 200
KERNEL = sys.argv[2] if len(sys.argv) > 2 else \
    "os/inferno/stm32f407/istm32f407"
CHARDELAY = 0.006


def boot():
    """A FRESH BOARD for each phase, and that is not tidiness.

    The backlog is cumulative, so the second phase inherited a hundred
    and forty thousand seconds of it from the first and then measured
    that DRAINING -- "not growing" was true and meant nothing.  A phase
    that asks whether the model keeps up has to start from a model that
    is up to date.
    """
    global p, out
    out = ""
    p = subprocess.Popen(["qemu-system-arm", "-M", "netduinoplus2",
                          "-nographic", "-serial", "null",
                          "-serial", "mon:stdio", "-kernel", KERNEL],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, bufsize=0)
    drain(10.0)


p = None
out = ""


def drain(secs):
    global out
    end = time.time() + secs
    got = ""
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.05)
        if r:
            d = p.stdout.read(4096)
            if d:
                got += d.decode("utf-8", "replace")
    out += got
    return got.replace("\r", "")


def send(line, settle=0.7):
    """One character at a time: the receive register is one byte deep
    and the echo is done from the interrupt handler, so a line written
    in one go arrives as a DIFFERENT line."""
    for ch in (line + "\n").encode():
        p.stdin.write(bytes([ch]))
        p.stdin.flush()
        time.sleep(CHARDELAY)
    return drain(settle)


bad = []


def phase(ts, reads, label, require):
    """Read the five files hard at one time scale and say what happened.

    THE BACKLOG IS THE POINT, not just the absence of a crash.  One
    advance() may take at most Maxsteps steps, so a single read can
    integrate at most Maxsteps times the step length -- 4096 x 50ms, or
    204.8 simulated seconds -- however long it has been since the last
    one.  Multiply the interval between reads by the time scale and if
    that exceeds the capacity the model falls behind, for ever, and the
    backlog says so.  The first version of this test asked only whether
    the backlog had QUADRUPLED and so reported "no growing backlog"
    about one that had cleanly doubled.
    """
    global out
    send("echo timescale %d >'#P/orbit.ctl'" % ts)
    send("echo tumble >'#P/imu.ctl'")
    send("echo 150 -90 40 >'#P/torque'")
    send("echo battery sim >'#P/power.ctl'")
    files = ["#P/imu", "#P/imu.ctl", "#P/power", "#P/orbit", "#P/battery"]
    marks = []
    for i in range(reads):
        got = send("cat '%s'" % files[i % len(files)], settle=0.6)
        m = re.search(r"^backlog (\d+)", got, re.M)
        if m:
            marks.append(int(m.group(1)))
        if "fatal" in got or "HardFault" in got or "panic" in got:
            bad.append(got[-300:])
            return False
    if "SOAK-MARKER" not in send("echo SOAK-MARKER", settle=1.5):
        print("SIMSOAK-FAILED %s: the board stopped answering after %d"
              " reads; its tail was:" % (label, reads))
        print("\n".join(out.replace("\r", "").splitlines()[-10:]))
        return False
    if not marks:
        print("SIMSOAK-FAILED %s: no backlog was ever reported" % label)
        return False
    half = len(marks) // 2
    first, last = max(marks[:half] or [0]), max(marks[half:] or [0])
    grew = last > first + 2000
    print("%-26s peak backlog %d ms then %d ms%s"
          % (label, first, last, ", GROWING" if grew else ""))
    if require and grew:
        print("SIMSOAK-FAILED %s: the integrator is falling behind at a"
              " time scale it is supposed to sustain" % label)
        return False
    if not require and grew:
        # Not a measured rate, so do not print one: state the capacity,
        # which is a property of the kernel, and what it means.
        print("    expected: one advance() integrates at most"
              " Maxsteps x step = 204800 simulated ms, so at timescale"
              " %d a reader has to come back within %d ms of board time"
              " to keep up.  This one does not, and the model says so"
              " rather than silently skipping the difference."
              % (ts, 204800 // ts))
    return True


try:
    # The stress: the fastest time scale, which is where the step loop,
    # the carried remainders and the renormalisation work hardest.
    # Falling behind here is expected and reported, not a failure.
    boot()
    ok1 = phase(200, READS, "timescale 200 (stress)", False)
    p.terminate(); p.wait()
    # And the one it must sustain: at timescale 1 a read asks for the
    # time since the last read and nothing more.
    ok2 = False
    if ok1:
        boot()
        ok2 = phase(1, READS // 2, "timescale 1 (must keep up)", True)
finally:
    if p is not None:
        p.terminate()
        p.wait()

if bad:
    print("SIMSOAK-FAILED the kernel faulted:")
    print(bad[0])
    sys.exit(1)
if not (ok1 and ok2):
    sys.exit(1)
print("SIMSOAK-OK %d reads of five simulated files at timescale 200 and"
      " %d at timescale 1, no fault, and the backlog bounded where it"
      " has to be" % (READS, READS // 2))
