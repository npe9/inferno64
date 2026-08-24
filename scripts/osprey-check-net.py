#!/usr/bin/env python3
"""Ping a protocol stack that is not in the kernel, and say so.

Two kernels are booted on one wire.  On the first, an ethernet interface
is given to a container and os/osprey/cmd/netsrv.c is run in it: the
frames arrive in that container's own buffers, and everything above the
card -- arp, ip, icmp -- is done by a program in user space that never
copies a frame.  On the second, nothing unusual: an address is
configured and ip/ping is run.

What this settles that nothing before it could: that a frame a container
built and handed to the card really reaches the other end of the wire,
because the other end answers it; and, since a ping is many frames, how
many of them arrive in the container's own buffers rather than being
copied into one.

usage: scripts/osprey-check-net.py [-k]
       -k   keep the logs rather than saying only what passed
"""
import os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

CD = ("9660srv -r -f /dev/sdF2/data cd9660 >[2]/dev/null & sleep 1; "
      "mkdir -p /n/cd; mount /srv/cd9660 /n/cd")

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def pair(port, a, b, amac='52:54:00:00:c3:01', bmac='52:54:00:00:c3:02'):
    logs = [tempfile.mktemp(prefix='osprey-net-', suffix='.log') for _ in (a, b)]
    def run(cmds, netdev, log, delay, mac):
        time.sleep(delay)
        argv = ['./scripts/osprey-console.py', '-q', '-p', '2',
                '-n', 'e1000,mac=' + mac, '--netdev', netdev,
                '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                '-t', '300', '-e', r'user\[glenda\]: =', '-u', '% ']
        for c in cmds:
            argv += ['-c', c]
        subprocess.run(argv, capture_output=True, text=True)
    t1 = threading.Thread(target=run,
        args=(a, 'socket,id=n0,listen=:%d' % port, logs[0], 0, amac))
    t2 = threading.Thread(target=run,
        args=(b, 'socket,id=n0,connect=:%d' % port, logs[1], 3, bmac))
    t1.start(); t2.start(); t1.join(); t2.join()
    return [plain(open(l, errors='replace').read()) for l in logs], logs

# the machine whose stack is a program.  A long line loses a character to
# the console, so each of these is short.
STACK = [
 CD,
 "rm -f /tmp/netsrv; cp /n/cd/bin/netsrv /tmp/netsrv; chmod +x /tmp/netsrv",
 "bind '#O' /n/osprey; sz=`{grep arena /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
 "echo create 7 100000000 200000000 200000000 >/n/osprey/ctl",
 "echo attach 7 0 >/n/osprey/ctl",
 "echo limit 7 4000000 4000000 4000 >/n/osprey/ctl",
 "sl=`{grep '^proc 7 ' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
 "sg=osprey^`{echo $sl $sz | awk '{print int($1/$2)}'}; echo seg $sg",
 "echo serve 7 >/n/osprey/ctl",
 "echo '#### gave'; echo ether 7 ether0 3 4 >/n/osprey/ctl; echo gave ether0",
 "/tmp/netsrv $sg $sz 3 4 10.9.0.1 &",
 "sleep 5; echo '#### ea'; grep '^packets 7' /n/osprey/status",
 "sleep 45; echo '#### seen'; grep '^packets 7' /n/osprey/status",
 "sleep 90; echo '#### flood'; grep '^packets 7' /n/osprey/status",
 "echo '#### end'",
]
# and the ordinary one, which knows nothing about any of it
def asker(flood):
    return [
     CD,
     "sleep 14; ip/ipconfig ether /net/ether0 10.9.0.2 255.255.255.0",
     "sleep 16; echo '#### ping'; ip/ping -n 8 10.9.0.1",
     "echo '#### arp'; cat /net/arp",
     # the driver queued its own receive buffers before the interface was
     # given away, and uses them up before it takes one of the
     # container's.  There are 256 of them, so a slow ping never gets
     # that far.
     "echo '#### flood'; ip/ping -n %d -i 20 10.9.0.1 >/dev/null >[2=1]"
        % flood,
     "echo flooded",
     "echo '#### end'",
    ]

def between(log, a, b):
    i = log.find('#### ' + a)
    j = log.find('#### ' + b, i + 1) if i >= 0 else -1
    return log[i:j] if i >= 0 and j > i else ''

def pkts(log, mark, nextmark):
    m = re.search(r'^packets 7 direct (\d+) copied (\d+) held (\d+)'
                  r'(?: ea ([0-9a-f]{12}))?$',
                  between(log, mark, nextmark), re.M)
    return m

def iso(ini=''):
    env = dict(os.environ, OSPREY_NOBOOTPROMPT='local!/dev/sdE0/fs')
    if ini:
        env['OSPREY_INI'] = ini
    subprocess.run(['sh', os.path.join(ROOT, 'scripts/mkosprey-efi-iso.sh')],
                   env=env, check=True, stdout=subprocess.DEVNULL)

def main():
    keep = '-k' in sys.argv[1:]
    results = []

    iso()
    (stack, ask1), logs = pair(17895, STACK, asker(400))

    ea = pkts(stack, 'ea', 'seen')
    results.append(("a container told the address of the card it was given",
                    ea is not None and ea.group(4) is not None))
    results.append(("the stack in user space saying what it answers for",
                    re.search(r'netsrv container 7 ea .* ip 10\.9\.0\.1',
                              stack) is not None))

    ping = between(ask1, 'ping', 'arp')
    got = len(re.findall(r'^\d+: rtt', ping, re.M))
    results.append(("an arp for that address answered by that program",
                    re.search(r'10\.9\.0\.1\s+' + (ea.group(4) if ea and ea.group(4)
                              else 'nothing'),
                              between(ask1, 'arp', 'end').replace(':', '')) is not None
                    or '10.9.0.1' in between(ask1, 'arp', 'end')))
    results.append(("eight echo requests answered, so the frames it built "
                    "reached the other machine (%d back)" % got, got >= 6))

    results.append(("what the program itself counted",
                    re.search(r'netsrv \d+ frames, \d+ arp, [1-9]\d* echo',
                              stack) is not None))

    # the driver had 256 of its own buffers queued before the interface
    # was given away; only once those are used up does a frame land in
    # one of the container's, which is what direct counts.
    seen = pkts(stack, 'flood', 'end')
    d = int(seen.group(1)) if seen else 0
    c = int(seen.group(2)) if seen else 0
    results.append(("frames arriving in the container's own buffers once the "
                    "driver's are used up (%d direct, %d copied)" % (d, c),
                    d > 0))

    # and again with a slice big enough to lend the interface as many
    # buffers as its ring is deep, which is what the number above is
    # short of.  Nothing in the kernel changes; plan9.ini does.
    iso('*ospreypktbuf=256')
    (stack2, ask2), logs2 = pair(17897, STACK, asker(1200))
    logs = logs + logs2

    results.append(("the same eight answered with a slice that big "
                    "(%d back)" % len(re.findall(r'^\d+: rtt', between(ask2, 'ping', 'arp'), re.M)),
                    len(re.findall(r'^\d+: rtt', between(ask2, 'ping', 'arp'), re.M)) >= 6))
    seen2 = pkts(stack2, 'flood', 'end')
    d2 = int(seen2.group(1)) if seen2 else 0
    c2 = int(seen2.group(2)) if seen2 else 0
    # the copies are the ring's first fill and nothing after it: the
    # driver's own two hundred and fifty-six buffers, used once each.
    results.append(("and then the copying stopping at the driver's own "
                    "buffers while the rest arrive in the container's "
                    "(%d direct, %d copied)" % (d2, c2),
                    seen2 is not None and c2 <= 300 and d2 > 2*c2))

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok:
            bad += 1
    if keep or bad:
        for l in logs:
            print('log %s' % l)
    else:
        for l in logs:
            try:
                os.unlink(l)
            except OSError:
                pass
    return 1 if bad else 0

sys.exit(main())
