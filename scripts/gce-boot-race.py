#!/usr/bin/env python3
# Time two Compute Engine instances from reset to the moment each one
# is usable, with the same clock and the same method.
#
# doc/inferno-cloud-modern.ms item 9 wants Inferno's boot compared with
# a conventional system's on the same instance shape.  The guest cannot
# time its own boot -- pc64's tick counter runs from machine reset, so
# /dev/time counts firmware as uptime (scripts/boot-profile.py says so
# at length) -- and the two guests have no clock in common anyway.  So
# the timing is done from outside: reset, then poll the serial port
# until the text that means "a person could type here now" appears, and
# report the wall-clock gap.
#
# What that measures is reset to usable, firmware included.  The
# firmware is the same on both, which is the point of running them on
# the same shape.
#
# Both ends are timed from the same point: the line the Compute Engine
# firmware prints when it hands control to the boot loader, which is
# "BdsDxe: starting" on every UEFI instance here, Inferno or Linux.  So
# the number is loader-to-usable and the firmware before it is excluded
# from both.  Counting occurrences of the ready marker alone is not
# enough -- output buffered before the reset lands after it and reads
# as an instant boot -- so each run waits for a NEW start line first
# and times from there.
#
# usage: gce-boot-race.py [-z zone] [-n runs] [-s start] NAME=MARKER ...
#   -z  zone (default us-central1-a)
#   -n  how many resets each (default 1)
#   -s  the start line (default "BdsDxe: starting")
#
# MARKER is plain text meaning "a person could use this now".
import getopt, re, subprocess, sys, time

zone, runs, start = "us-central1-a", 1, "BdsDxe: starting"
opts, args = getopt.getopt(sys.argv[1:], "z:n:s:")
for o, v in opts:
    if o == "-z": zone = v
    elif o == "-n": runs = int(v)
    elif o == "-s": start = v
if not args:
    sys.stderr.write("usage: gce-boot-race.py [-z zone] [-n runs] NAME=MARKER ...\n")
    raise SystemExit(2)

def serial(name, start=None):
    """New serial output since `start`, and the offset to ask for next.

    The API returns a window of the log, not the whole thing, so
    counting occurrences of a marker breaks once a talkative guest has
    pushed the early text out of it -- a Debian instance does that in a
    few boots and the count goes DOWN.  Byte offsets do not have that
    problem: gcloud names the next one on stderr.
    """
    cmd = ["gcloud", "compute", "instances", "get-serial-port-output",
        name, "--zone", zone]
    if start is not None:
        cmd.append("--start=%d" % start)
    p = subprocess.run(cmd, capture_output=True, text=True)
    m = re.search(r"--start=(\d+)", p.stderr)
    return p.stdout, (int(m.group(1)) if m else start)

def reset(name):
    subprocess.run(["gcloud", "compute", "instances", "reset", name,
        "--zone", zone], capture_output=True, text=True)

results = {}
for spec in args:
    name, marker = spec.split("=", 1)
    times = []
    for i in range(runs):
        _, off = serial(name)            # skip everything said so far
        reset(name)
        t0 = None
        seen = None
        began = time.time()
        while time.time() - began < 900:
            text, off = serial(name, off)
            if t0 is None:
                if start in text:
                    t0 = time.time()
                    text = text.split(start, 1)[1]
            if t0 is not None and marker in text:
                seen = time.time() - t0
                break
            time.sleep(1)
        times.append(seen)
        print("%s run %d: %s" % (name, i+1,
            "%.0f s" % seen if seen is not None else "never appeared"))
    results[name] = times

print()
for name, times in results.items():
    got = [t for t in times if t is not None]
    if got:
        print("%-20s %s  (median %.0f s)" % (name,
            " ".join("%.0f" % t for t in got), sorted(got)[len(got)//2]))
    else:
        print("%-20s never reached its marker" % name)
print("\nreset to marker, polled every 2 s from outside, firmware included")
