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
faults too, since exec: the binary is /boot/legacy in the buddy's file
system, laid out and paged by it).
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
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9buddy'), OSPREY_INI='ospreykey=this machine\'s secret'),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = tempfile.mktemp(prefix='osprey-p9buddy-', suffix='.log')
    subprocess.run(['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
                    '-l', log, '-S', '-d', ROOT + '/.qemu/9front-root.qcow2',
                    '-t', '150', '-u', 'the microkernel idles'],
                   env=env, capture_output=True, text=True)
    try: t = plain(open(log, errors='replace').read())
    except OSError: t = ''

    m = re.search(r'read\(fd, buf, \d+\) returned (\d+) bytes, served by the buddy', t)
    sl = re.search(r'nsec\(\) ran forward (\d+) milliseconds over a 50 millisecond sleep', t)
    results = [
        ("an unmodified Plan 9 binary runs on the microkernel and a buddy personality serves it",
         'unmodified Plan 9 program' in t and 'p9 server: serving this name space over the ring' in t),
        ("the buddy lays the a.out out from its own file system and pages it in; the kernel carries no copy",
         'buddy: exec /boot/legacy for container' in t and 'a Plan 9 a.out, text' in t
         and 'laid out by the buddy' in t and 'page 0x200000 of the legacy image supplied from its file' in t),
        ("its open() traps in the Plan 9 ABI and the buddy answers with a descriptor",
         re.search(r'legacy: open\("/"\) returned fd \d+', t) is not None),
        ("its read() is forwarded and the buddy returns the file's bytes, copied back to the legacy buffer",
         m is not None and int(m.group(1)) > 0),
        # The calls beyond the files.  A buddy answers what a program asks
        # of its file system; these four are asked of the machine, and the
        # machine is the microkernel - p9pair's systab had xbrk, xalarm,
        # xrendezvous and xnsec and this configuration's had none of them.
        # EXEC is deliberately not among them: here the buddy is the loader
        # and the pager and answers EXEC itself.
        ("and the calls beyond the files are the kernel's, not the buddy's: rendezvous(2) meets two processes of one address space and passes a word between them",
         'rendezvous on tag 0x9001 met my thread and took the word it left: 0x1234' in t),
        ("and brk(2) grows the heap the microkernel gave the program, so a buffer malloc returns is in the address space both flows share",
         'the heap is shared too: what my thread wrote into a buffer malloc gave me reads back here' in t),
        # sleep(2) was the real fault under these.  Every sleep of a legacy
        # process was the two-millisecond yield the ring clients use,
        # whatever it asked for - p9pair had fixed this and said so in a
        # comment, and this configuration had not - so the program's forty
        # 20ms sleeps waiting for a 150ms alarm all returned in about two,
        # it gave up before the alarm was due, and called the kernel's
        # alarm broken.  Both numbers below are of that one fault: a sleep
        # that returns early is a clock that lies to every program that
        # waits on one.
        ("and sleep(2) sleeps for the time asked rather than yielding, which is what the program's own clock says: nsec(2) reads a rising 50 milliseconds across a 50-millisecond sleep, where a two-millisecond yield read 2",
         sl is not None and 45 <= int(sl.group(1)) <= 70),
        ("and alarm(2) delivers its note to the handler the program registered, which only a sleep that really sleeps can wait for",
         'my note handler got the alarm note I asked for' in t
         and 'alarm(150) delivered its note and I woke to it' in t),
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
