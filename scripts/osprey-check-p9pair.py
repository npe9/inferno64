#!/usr/bin/env python3
"""Boot p9pair: two Plan 9 personalities as buddies over the ring.

p9pair is the microkernel running two containers, each the Plan 9 file
personality as a user-space library.  One is the client, the other the
server; the client delegates to the server, so its 9P requests forward
over the ring, and the server answers them from its own name space by an
exportfs.  This is the paper's library-OS mechanism ("library operating
systems on top of the Osprey kernel") with two of them, one delegating
file operations to the other - one-directional, and NOT the paper's
buddyOS, which is legacy-binary system-trap emulation, a different and
unbuilt mechanism.
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

    m = re.search(r"pair-client: read (\d+) entries from the server personality's exported root", t)
    results = [
        ("the microkernel runs a client personality that mounts a second personality over the ring",
         'pair-client: mounting the server personality over the ring' in t),
        ("and a second personality, a container of its own, answers 9P about its name space",
         'server personality: name space up, answering 9P over the ring' in t and 'p9 server: serving this name space over the ring' in t),
        ("and the client reads the server personality's exported root over 9P, the kernel only routing",
         m is not None and int(m.group(1)) >= 10),
        ("and it exits cleanly, two library operating systems on the microkernel, one serving the other, no panic",
         'the program exited' in t and 'panic' not in t),
        ("a request exec starts a program - the Linux binary in the server's file system - in a container of its own, delegated to the same server",
         re.search(r'osprey exec: container (\d+) starts /boot/linux for container 1, served by container 3', t) is not None
         and re.search(r'p9: pair-client: exec /boot/linux started container \d+', t) is not None),
        ("the server lays it out and pages it in, and it runs to exit: its file calls, brk and mmap answered",
         'buddy: exec /boot/linux for container' in t and 'linux: read(fd, buf, 512) returned 470 bytes' in t
         and 'linux: brk grew the heap by 65536 bytes, zero-filled' in t
         and re.search(r'osprey exec: container \d+ \(/boot/linux\) exited with status 0', t) is not None),
        ("wait is answered by somebody: the client's wait returns the child's exit status",
         re.search(r'p9: pair-client: wait: container \d+ exited with status 0', t) is not None
         and 'panic' not in t and 'user fault' not in t),
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
