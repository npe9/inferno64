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
#   -T  stamp each line with seconds since the first command was typed
#
# Each CMD is typed as one line.  Everything the console printed is
# written to stdout as it arrives, carriage returns removed.  With -T
# each line carries the seconds since the first command went in, which
# is how a command that takes a while on the guest -- a TLS handshake,
# say -- is timed without a clock in the guest to do it with.  Exit status 1 if the
# prompt never appeared -- that is a boot that did not finish, and it is
# reported as such rather than as a command that printed nothing.
import getopt, os, pty, select, signal, subprocess, sys, time

zone, quiet, prompt, limit, stamp = "us-central1-a", 20.0, "; ", 300.0, False
opts, args = getopt.getopt(sys.argv[1:], "z:w:p:t:T")
for o, v in opts:
    if o == "-z": zone = v
    elif o == "-w": quiet = float(v)
    elif o == "-p": prompt = v
    elif o == "-t": limit = float(v)
    elif o == "-T": stamp = True
if len(args) < 1:
    sys.stderr.write("usage: gce-console.py [-z zone] [-w secs] [-p pat] INSTANCE CMD...\n")
    sys.exit(2)
inst, cmds = args[0], args[1:]

pid, fd = pty.fork()
if pid == 0:
    os.execvp("gcloud", ["gcloud", "compute", "connect-to-serial-port", inst,
        "--zone", zone, "--port", "1"])

out = bytearray()
t0 = None		# set when the first command is typed
partial = ""		# a line the console has not finished sending

def emit(text):
    # -T stamps whole lines only, so a prompt with no newline after it
    # is held rather than stamped twice
    global partial
    if not stamp:
        sys.stdout.write(text)
        sys.stdout.flush()
        return
    partial += text
    while "\n" in partial:
        line, partial = partial.split("\n", 1)
        el = 0.0 if t0 is None else time.time() - t0
        sys.stdout.write("%7.2f %s\n" % (el, line))
    sys.stdout.flush()

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
        # written as it arrives, so a caller's timeout loses nothing
        emit(b.decode("utf-8", "replace").replace("\r", ""))
        last = time.time()
        if until is not None and until.encode() in out[start:]:
            return True
    return until is None

# The proxy replays what the console printed before this connection, so
# first let that backlog run out; anything after the quiet is this
# session's.  Then press return until a prompt comes back, for as long
# as the boot may take.
pump(3)
ok = False
deadline = time.time() + limit
while time.time() < deadline:
    os.write(fd, b"\r")
    if pump(5, prompt):
        ok = True
        break
def typeline(line):
    # A character at a time: the guest's console loses input sent as
    # one burst -- a port number typed as "17010" arrived as "17" --
    # and nothing in the path offers flow control.
    for ch in line.encode() + b"\r":
        os.write(fd, bytes([ch]))
        time.sleep(0.03)

if ok:
    for c in cmds:
        if t0 is None:
            t0 = time.time()
        typeline(c)
        pump(quiet)
    emit("\n")
os.kill(pid, signal.SIGTERM)
sys.exit(0 if ok else 1)
