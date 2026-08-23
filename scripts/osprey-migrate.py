#!/usr/bin/env python3
"""Move a container from one machine to another.

Two kernels are booted on one wire -- a qemu socket network, which is
two virtual machines and a cable and nothing else.  A container is made
on the first, and its checkpoint is carried to the second in an ethernet
frame of its own type, where it is read back into a kernel that had never
heard of it.

usage: scripts/osprey-migrate.py
"""
import os, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

SOURCE = [
  "9660srv -r -f /dev/sdF2/data cd9660 >[2]/dev/null & sleep 1; mkdir -p /n/cd; mount /srv/cd9660 /n/cd; rm -f /tmp/mig; cp /n/cd/bin/mig /tmp/mig; chmod +x /tmp/mig",
  "bind '#O' /n/osprey; echo create 42 40000000 800000000 200000000 >/n/osprey/ctl; echo attach 42 1 >/n/osprey/ctl; echo bind 42 home /usr/glenda >/n/osprey/ctl; echo mode 42 strict >/n/osprey/ctl",
  "grep -e '^proc 42' -e '^name 42' /n/osprey/status",
  "sleep 6; /tmp/mig send",
  "grep -c '^proc ' /n/osprey/status",
]

DEST = [
  "9660srv -r -f /dev/sdF2/data cd9660 >[2]/dev/null & sleep 1; mkdir -p /n/cd; mount /srv/cd9660 /n/cd; rm -f /tmp/mig; cp /n/cd/bin/mig /tmp/mig; chmod +x /tmp/mig",
  "bind '#O' /n/osprey; echo 'containers here:'; grep -c '^proc ' /n/osprey/status",
  "/tmp/mig recv",
  "grep -e '^proc 42' -e '^name 42' -e '^core 1' /n/osprey/status",
]

def run(name, netdev, cmds, log, delay):
    time.sleep(delay)
    argv = ['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
            '--netdev', netdev, '-l', log, '-S',
            '-d', ROOT + '/.qemu/9front-root.qcow2', '-t', '200',
            '-e', 'user\\[glenda\\]: =', '-u', '% ']
    for c in cmds:
        argv += ['-c', c]
    r = subprocess.run(argv, capture_output=True, text=True)
    print('%s exit %d' % (name, r.returncode))

# the destination listens, the source connects a moment later
t1 = threading.Thread(target=run, args=('dest', 'socket,id=n0,listen=:17777',
        DEST, '/tmp/dest.log', 0))
t2 = threading.Thread(target=run, args=('source', 'socket,id=n0,connect=:17777',
        SOURCE, '/tmp/source.log', 3))
t1.start(); t2.start()
t1.join(); t2.join()
