#!/usr/bin/env python3
"""Boot p9buddy: a buddy operating system serving an unmodified Plan 9 binary.

p9buddy runs an unmodified Plan 9 program in one container and a Plan 9
personality in a second.  The legacy program opens and reads a file with
the ordinary library, which traps in the Plan 9 system-call ABI; the
microkernel does not implement those calls, so it forwards each trap over
the ring to the peer - the buddy operating system - which emulates it
against its own name space and descriptor table and answers.  The legacy
program cannot tell a peer served it.  This is the paper's buddyOS: per-
process trap interposition, Plan 9 ABI, system calls (not yet page
faults, since the legacy image is eager-mapped).
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9buddy', '9p9buddy'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9buddy did not build'); print(r.stdout[-800:]); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9buddy')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9buddy-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: t = plain(open(log, errors='replace').read())
    except OSError: t = ''

    m = re.search(r'read\(fd, buf, \d+\) returned (\d+) bytes, served by the buddy', t)
    results = [
        ("an unmodified Plan 9 binary runs on the microkernel and a buddy personality serves it",
         'unmodified Plan 9 program' in t and 'p9 server: serving this name space over the ring' in t),
        ("its open() traps in the Plan 9 ABI and the buddy answers with a descriptor",
         'open("/") returned fd 0' in t),
        ("its read() is forwarded and the buddy returns the file's bytes, copied back to the legacy buffer",
         m is not None and int(m.group(1)) > 0),
        ("every file trap was served by the peer, and it exits cleanly, no unimplemented syscall, no panic",
         'the buddy answered every trap' in t and 'unimplemented syscall' not in t
         and 'the program exited' in t and 'panic' not in t),
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
