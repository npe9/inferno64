#!/usr/bin/env python3
# Type commands at a Compute Engine instance's serial console and print
# what came back.
#
# The rented-instance half of scripts/type-at-console.py.  An Inferno
# image has no ssh server and no startup-script agent, so the serial
# port is the only way in: "gcloud compute connect-to-serial-port" is an
# ssh session to Google's serial proxy, and it wants a terminal, so it
# is run on a pseudo-tty here rather than a pipe.
#
# The instance needs metadata serial-port-enable=TRUE.
#
# usage: gce-console.py [-z zone] [-w secs] [-p pattern] INSTANCE CMD...
#   -z  zone (default us-central1-a)
#   -w  how long to wait for each command's output to go quiet (default 20)
#   -p  wait for this text before typing anything (default "; ")
#   -t  give up waiting for the prompt after this many seconds (default 300)
#
# Each CMD is typed as one line.  Everything the console printed is
# written to stdout, carriage returns removed.  Exit status 1 if the
# prompt never appeared -- that is a boot that did not finish, and it is
# reported as such rather than as a command that printed nothing.
import getopt, os, pty, select, signal, subprocess, sys, time

zone, quiet, prompt, limit = "us-central1-a", 20.0, "; ", 300.0
opts, args = getopt.getopt(sys.argv[1:], "z:w:p:t:")
for o, v in opts:
    if o == "-z": zone = v
    elif o == "-w": quiet = float(v)
    elif o == "-p": prompt = v
    elif o == "-t": limit = float(v)
if len(args) < 1:
    sys.stderr.write("usage: gce-console.py [-z zone] [-w secs] [-p pat] INSTANCE CMD...\n")
    sys.exit(2)
inst, cmds = args[0], args[1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp("gcloud", ["gcloud", "compute", "connect-to-serial-port", inst,
        "--zone", zone, "--port", "1"])

out = bytearray()
def pump(secs, until=None):
    # read until secs pass with nothing new, or until `until` appears
    # in what arrived after `start`; return whether `until` was seen
    start = len(out)
    last = time.time()
    while time.time() - last < secs:
        r, _, _ = select.select([fd], [], [], 0.5)
        if not r:
            continue
        try:
            b = os.read(fd, 4096)
        except OSError:
            return False
        if not b:
            return False
        out.extend(b)
        last = time.time()
        if until is not None and until.encode() in out[start:]:
            return True
    return until is None

# The proxy prints its banner and then nothing: an Inferno shell has
# already printed its prompt before anyone connected.  So press return
# until a prompt comes back, for as long as the boot may take.
ok = False
deadline = time.time() + limit
while time.time() < deadline:
    os.write(fd, b"\r")
    if pump(5, prompt):
        ok = True
        break
if ok:
    for c in cmds:
        os.write(fd, c.encode() + b"\r")
        pump(quiet)
os.kill(pid, signal.SIGTERM)
sys.stdout.write(out.decode("utf-8", "replace").replace("\r", ""))
sys.exit(0 if ok else 1)
