#!/usr/bin/env python3
# Reset a Compute Engine instance and stamp its console output as it
# arrives, so a boot can be timed in fractions of a second.
#
# The obvious instrument -- poll "get-serial-port-output" and watch for
# a line -- cannot do this: the API hands back the log in bursts, so a
# fast boot's first and last markers turn up in the same poll and the
# answer comes out as 0 seconds.  scripts/gce-boot-race.py is that
# instrument and its numbers are only good to a few seconds.  This one
# holds the live stream open (the same ssh session
# "gcloud compute connect-to-serial-port" gives, on a pseudo-tty) and
# stamps every line with the local clock.
#
# The zero is the line the firmware prints when it hands control to the
# boot loader -- "BdsDxe: starting" on every UEFI instance here -- so
# what is timed is loader-to-marker, and the firmware before it is
# excluded, the same way for whatever is being compared.
#
# usage: gce-boot-stamp.py [-z zone] [-s start] [-w secs] INSTANCE MARKER...
#   -z  zone (default us-central1-a)
#   -s  the zero line (default "BdsDxe: starting")
#   -w  stop this long after the zero line (default 90)
#
# Each MARKER is plain text; the first line containing it is reported
# with its offset from the zero line.  Every line is printed with its
# own offset too, so the whole boot is visible.
import getopt, os, pty, re, select, signal, subprocess, sys, time

zone, start, window = "us-central1-a", "BdsDxe: starting", 90.0
opts, args = getopt.getopt(sys.argv[1:], "z:s:w:")
for o, v in opts:
    if o == "-z": zone = v
    elif o == "-s": start = v
    elif o == "-w": window = float(v)
if len(args) < 1:
    sys.stderr.write("usage: gce-boot-stamp.py [-z zone] [-s start] [-w secs] INSTANCE MARKER...\n")
    raise SystemExit(2)
inst, markers = args[0], args[1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp("gcloud", ["gcloud", "compute", "connect-to-serial-port",
        inst, "--zone", zone, "--port", "1"])

# let the proxy connect and replay its backlog before resetting
deadline = time.time() + 20
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try:
            os.read(fd, 65536)
        except OSError:
            break

subprocess.run(["gcloud", "compute", "instances", "reset", inst,
    "--zone", zone], capture_output=True, text=True)

t0 = None
hits = {}
buf = b""
began = time.time()
while time.time() - began < 600:
    if t0 is not None and time.time() - t0 > window:
        break
    r, _, _ = select.select([fd], [], [], 1.0)
    if not r:
        continue
    try:
        b = os.read(fd, 65536)
    except OSError:
        break
    if not b:
        break
    now = time.time()
    buf += b
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        s = line.decode("utf-8", "replace").replace("\r", "")
        if t0 is None:
            if start in s:
                t0 = now
                print("%7.2f  %s" % (0.0, s))
            continue
        print("%7.2f  %s" % (now - t0, s))
        for m in markers:
            if m in s and m not in hits:
                hits[m] = now - t0

os.kill(pid, signal.SIGTERM)
print()
if t0 is None:
    print("%s: the zero line never arrived" % inst)
    raise SystemExit(1)
for m in markers:
    print("%-24s %s" % (m, "%.2f s" % hits[m] if m in hits else "never appeared"))
