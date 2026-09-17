#!/usr/bin/env python3
"""The pairing offer against a listener that is not ready yet.

Two machines agree a key over the wire: one says offer and one says
listen, and neither has been told what the other is called.  Which of
them is ready first is not either machine's to arrange, and the offer
used to be said once - so if the listener was not up yet the frame went
into the wire with nobody to hear it, and both machines ended holding no
key at all.  That is what the two-machine check's transient was: it
gives the listener a head start of a few seconds, and a loaded host is
enough to spend it.

This is the falsification: the listener is held back forty seconds on
purpose, which no head start covers.  Against the kernel before the
offer was repeated it says NO KEY, and against this one the two agree.

usage: scripts/osprey-check-pair.py [-k]
"""
import os, re, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

OFFER = [
 "bind '#O' /n/osprey; echo pair ether0 offer >/n/osprey/ctl",
 "for(i in `{seq 1 70}){ k=`{grep '^key ' /n/osprey/status}; "
 "if(! ~ $\"k 'key none') break; sleep 1 }; grep '^key ' /n/osprey/status",
]
# forty seconds of not listening, which is longer than any head start a
# check could give and longer than the offer's own patience used to be
LISTEN = [
 "sleep 40; bind '#O' /n/osprey; echo pair ether0 listen >/n/osprey/ctl",
 "for(i in `{seq 1 40}){ k=`{grep '^key ' /n/osprey/status}; "
 "if(! ~ $\"k 'key none') break; sleep 1 }; grep '^key ' /n/osprey/status",
]

def keyof(path):
    t = re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '',
               open(path, errors='replace').read())
    m = re.findall(r'^key ([0-9a-f]{16})$', t, re.M)
    return m[-1] if m else None

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=pc64', '9pc64'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9pc64 did not build')
        return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_NOBOOTPROMPT='local!/dev/sdE0/fs'),
                   check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)

    logs = [tempfile.mktemp(prefix='osprey-pair-', suffix='.log') for _ in (0, 1)]
    def run(cmds, netdev, log, delay, mac):
        time.sleep(delay)
        argv = ['./scripts/osprey-console.py', '-q', '-p', '2',
                '-n', 'e1000,mac=' + mac, '--netdev', netdev,
                '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                '-t', '200', '-e', r'user\[glenda\]: =', '-u', '% ']
        for c in cmds:
            argv += ['-c', c]
        subprocess.run(argv, env=env, capture_output=True, text=True)
    t1 = threading.Thread(target=run, args=(LISTEN, 'socket,id=n0,listen=:17995',
                                            logs[0], 0, '52:54:00:00:e1:01'))
    t2 = threading.Thread(target=run, args=(OFFER, 'socket,id=n0,connect=:17995',
                                            logs[1], 3, '52:54:00:00:e1:02'))
    t1.start(); t2.start(); t1.join(); t2.join()

    ka, kb = keyof(logs[0]), keyof(logs[1])
    ok = ka is not None and ka == kb
    print('%-4s %s' % ('ok' if ok else 'FAIL',
          "a key agreed with a listener forty seconds late: the offer is said "
          "again until it is answered, so which machine is ready first is not "
          "the protocol's business (listener %s, offerer %s)" % (ka, kb)))
    if keep or not ok:
        for l in logs:
            print('log %s' % l)
    else:
        for l in logs:
            try:
                os.unlink(l)
            except OSError:
                pass
    return 0 if ok else 1

sys.exit(main())
