#!/usr/bin/env python3
"""Boot p9pair: two Plan 9 personalities as buddies over the ring.

p9pair is the microkernel running two containers, each the Plan 9 file
personality as a user-space library.  One is the client, the other the
server; the client delegates to the server, so its 9P requests forward
over the ring, and the server answers them from its own name space by an
exportfs.  Two library operating systems then name each other's files by
message passing, the kernel only routing - the paper's picture, with a
real container boundary rather than a loopback.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9pair', '9p9pair'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9pair did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9pair-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: t = plain(open(log, errors='replace').read())
    except OSError: t = ''

    m = re.search(r"pair-client: read (\d+) entries from the buddy's exported root", t)
    results = [
        ("the microkernel runs a client personality that mounts a buddy over the ring",
         'pair-client: mounting the buddy personality over the ring' in t),
        ("and a second personality, a container of its own, answers 9P about its name space",
         'buddy server: name space up, answering 9P over the ring' in t and 'p9 buddy: serving this name space over the ring' in t),
        ("and the client reads the buddy's exported root over 9P, the kernel only routing",
         m is not None and int(m.group(1)) >= 10),
        ("and it exits cleanly, two library operating systems as buddies, no panic",
         'the program exited' in t and 'panic' not in t),
    ]
    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    if keep or bad: print('log %s' % log)
    else:
        try: os.unlink(log)
        except OSError: pass
    return 1 if bad else 0

sys.exit(main())
