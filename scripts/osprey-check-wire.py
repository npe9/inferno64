#!/usr/bin/env python3
"""Run everything that takes two machines, and say so.

Two kernels are booted on one wire -- a qemu socket network, which is two
virtual machines and a cable and nothing else -- and driven through the
commands below.  What is checked is the whole of what needs another
machine: a key agreed rather than typed into both, pi-p spoken in frames
of its own, a session that must prove who it is before it may have a
container, an attribute arriving at a rate nobody asked for again, a
container carried across and restarted, and a checkpoint too big for a
frame refused rather than half-sent.

usage: scripts/osprey-check-wire.py [-k]
       -k   keep the logs rather than saying only what passed

The single-machine half is scripts/osprey-check.py.
"""
import os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

CD = ("9660srv -r -f /dev/sdF2/data cd9660 >[2]/dev/null & sleep 1; "
      "mkdir -p /n/cd; mount /srv/cd9660 /n/cd")

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def pair(port, a, b, amac='52:54:00:00:c1:01', bmac='52:54:00:00:c1:02'):
    """Boot two machines on one wire; a listens, b connects a moment later."""
    logs = [tempfile.mktemp(prefix='osprey-wire-', suffix='.log') for _ in (a, b)]
    def run(cmds, netdev, log, delay, mac):
        time.sleep(delay)
        argv = ['./scripts/osprey-console.py', '-q', '-p', '2',
                '-n', 'e1000,mac=' + mac, '--netdev', netdev,
                '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                '-t', '260', '-e', r'user\[glenda\]: =', '-u', '% ']
        for c in cmds:
            argv += ['-c', c]
        subprocess.run(argv, capture_output=True, text=True)
    t1 = threading.Thread(target=run,
        args=(a, 'socket,id=n0,listen=:%d' % port, logs[0], 0, amac))
    t2 = threading.Thread(target=run,
        args=(b, 'socket,id=n0,connect=:%d' % port, logs[1], 3, bmac))
    t1.start(); t2.start(); t1.join(); t2.join()
    return [plain(open(l, errors='replace').read()) for l in logs], logs

# the machine that answers, and the one that asks
SERVER = [
 CD,
 "bind '#O' /n/osprey; echo pair ether0 listen >/n/osprey/ctl",
 "sleep 14; grep '^key ' /n/osprey/status",
 "echo create 7 100000000 200000000 200000000 >/n/osprey/ctl",
 "echo grant 7 fred >/n/osprey/ctl; echo pipether ether0 on >/n/osprey/ctl",
 "sleep 50; echo server done",
]
CLIENT = [
 CD + "; rm -f /tmp/pip; cp /n/cd/bin/pip /tmp/pip; chmod +x /tmp/pip",
 "bind '#O' /n/osprey; sleep 6; echo pair ether0 offer >/n/osprey/ctl",
 "sleep 10; grep '^key ' /n/osprey/status",
 "echo create 7 100000000 200000000 200000000 >/n/osprey/ctl",
 "echo grant 7 fred >/n/osprey/ctl",
 "t=`{{echo '7 fred 0' >[1=0]; cat} <>/n/osprey/ticket}; echo ticket $t",
 "echo '#### wire'; sleep 8; /tmp/pip -e open 1 / read 1 '*' close 1",
 "echo '#### noticket'; /tmp/pip -e open 1 /7 read 1 budget close 1",
 "echo '#### ticket'; /tmp/pip -e auth $\"t open 1 /7 read 1 budget close 1",
 "echo '#### stream'; /tmp/pip -e auth $\"t open 3 /7 stream 3 500 6 used",
 "echo '#### toolong'; a=()",
 "for(i in `{seq 1 14}) a=($a read 1 '*')",
 "/tmp/pip -e auth $\"t open 1 /7 $a",
 "echo '#### end'",
]

# and the pair that carries a container across, and the one that will not fit
SRC = [
 CD + "; rm -f /tmp/mig; cp /n/cd/bin/mig /tmp/mig; chmod +x /tmp/mig",
 "bind '#O' /n/osprey; echo key sekrit >/n/osprey/ctl",
 "echo create 42 40000000 800000000 200000000 >/n/osprey/ctl",
 "echo attach 42 0 >/n/osprey/ctl; echo bind 42 home /usr/glenda >/n/osprey/ctl",
 # a semaphore given and not yet taken is state the microkernel keeps for
 # the container, and it goes with it
 "for(i in 1 2 3 4) echo semup 42 6 >/n/osprey/ctl",
 "echo '#### migrate'; sleep 8; /tmp/mig send",
 "echo '#### left'; grep -c '^proc ' /n/osprey/status",
 # now the other machine holds a different key
 "echo create 44 40000000 800000000 200000000 >/n/osprey/ctl",
 "echo attach 44 0 >/n/osprey/ctl",
 "echo '#### wrongkey'; sleep 12; /tmp/mig send",
 "echo '#### stillhere'; grep -c '^proc ' /n/osprey/status",
 # one container with a full ring still fits in a frame; two do not
 "for(c in 41 43) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
 "for(c in 41 43) echo attach $c 0 >/n/osprey/ctl",
 "for(c in 41 43) echo limit $c 262144 65536 64 >/n/osprey/ctl",
 "for(c in 41 43) for(i in 1 2 3 4 5 6 7 8) echo submit $c alloc 4096 >/n/osprey/ctl",
 "for(c in 41 43) for(i in 1 2 3 4 5 6 7 8) echo submit $c alloc 4096 >/n/osprey/ctl",
 "echo '#### toobig'; /tmp/mig send",
 "echo '#### kept'; grep -c '^proc ' /n/osprey/status",
 "echo '#### end'",
]
DST = [
 CD + "; rm -f /tmp/mig; cp /n/cd/bin/mig /tmp/mig; chmod +x /tmp/mig",
 "bind '#O' /n/osprey; echo key sekrit >/n/osprey/ctl",
 "echo '#### arrived'; /tmp/mig recv",
 "grep '^name 42' /n/osprey/status",
 # the names came with it, so they still resolve here: a container's
 # name space is its own table and not a Pgrp, which is what lets it
 # cross at all
 "echo '#### sem'; grep '^sem 42 ' /n/osprey/status | awk '{print \"sem6\", $9}'",
 "echo '#### opened'; echo poke 42 0 home >/n/osprey/ctl",
 "echo submit 42 open 0 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
 "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply",
 "echo key other >/n/osprey/ctl; echo '#### refuse'; /tmp/mig recv",
 "sleep 12; echo '#### only'; grep -c '^proc ' /n/osprey/status",
 "echo '#### end'",
]

def between(log, a, b):
    i = log.find('#### ' + a)
    j = log.find('#### ' + b, i + 1) if i >= 0 else -1
    return log[i:j] if i >= 0 and j > i else ''

def keyof(log):
    m = re.findall(r'^key ([0-9a-f]{16})$', log, re.M)
    return m[-1] if m else None

def main():
    keep = '-k' in sys.argv[1:]
    results = []
    kept = []

    # once, before either machine starts: the two boot at the same time
    # and would race building it.  An iso without the root device in its
    # plan9.ini stops at bootargs and everything below fails at once.
    subprocess.run(['sh', os.path.join(ROOT, 'scripts/mkosprey-efi-iso.sh')],
                   env=dict(os.environ,
                            OSPREY_NOBOOTPROMPT='local!/dev/sdE0/fs'),
                   check=True, stdout=subprocess.DEVNULL)

    (srv, cli), logs = pair(17891, SERVER, CLIENT)
    kept += logs
    ka, kb = keyof(srv), keyof(cli)
    results.append(("a key agreed over the wire, the same on both",
                    ka is not None and ka == kb))
    results.append(("pi-p answered in a frame of its own",
                    'Rread' in between(cli, 'wire', 'noticket')))
    results.append(("a container refused to a session that has not said who it is",
                    'not yours' in between(cli, 'noticket', 'ticket')))
    results.append(("and given to one that presents a ticket signed by that key",
                    "Rauth" in between(cli, 'ticket', 'stream')
                    and "Rread" in between(cli, 'ticket', 'stream')))
    results.append(("an attribute arriving six times at the rate it was asked for",
                    between(cli, 'stream', 'toolong').count('Rread') == 6))
    results.append(("a group whose replies will not fit a frame told so, not cut",
                    'do not fit' in between(cli, 'toolong', 'end')))

    (src, dst), logs = pair(17893, SRC, DST,
                            '52:54:00:00:c2:01', '52:54:00:00:c2:02')
    kept += logs
    results.append(("a container carried to the other machine and restarted",
                    'restarted' in dst and 'name 42 home /usr/glenda' in dst))
    results.append(("and gone from the one it left",
                    between(src, 'left', 'end').find('\n0\n') >= 0))
    results.append(("a semaphore's count arriving with it, given four times "
                    "and taken none",
                    'sem6 4/4/0' in between(dst, 'sem', 'opened')))
    results.append(("and the names it carried still opening what they name there",
                    '42 open done' in between(dst, 'opened', 'refuse')))
    results.append(("a checkpoint signed by a key the other end does not hold, refused",
                    'would not take it' in between(dst, 'refuse', 'only')))
    results.append(("and the container kept, since nothing said it arrived",
                    between(src, 'stillhere', 'toobig').find('\n1\n') >= 0))
    results.append(("a checkpoint too big for a frame refused, not half-sent",
                    'does not fit in one frame' in between(src, 'toobig', 'kept')))
    # 44, which the other end would not take, and 41 and 43, which
    # would not fit in a frame
    results.append(("with everything it would have sent still there",
                    between(src, 'kept', 'end').find('\n3\n') >= 0
                    and between(dst, 'only', 'end').find('\n1\n') >= 0))

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok:
            bad += 1
    if keep or bad:
        for l in kept:
            print('log %s' % l)
    else:
        for l in kept:
            try:
                os.unlink(l)
            except OSError:
                pass
    return 1 if bad else 0

sys.exit(main())
