#!/usr/bin/env python3
"""Run everything a single machine can be asked to prove, and say so.

One kernel is booted and driven through the commands below; each one
looks for something in what came back.  What is checked is the whole of
what osprey(3) says a single machine does: a request submitted and
collected through the mapped ring with no trap, a select waiting on a
reply and on a semaphore, a page written by one container and read by
another after it is handed over, a private name, a checkpoint carrying a
request that was still in flight along with the buffer it named, and a
uart driven by a task, whose output is watched on the second serial
port.

usage: scripts/osprey-check.py [-k]
       -k   keep the log rather than saying only what passed

The two-machine half is scripts/osprey-check-wire.py.
"""
import os, re, subprocess, sys, tempfile, time

class _None2: pass
None2 = _None2()   # a check whose answer is a time rather than a string

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

LOG = tempfile.mktemp(prefix='osprey-check-', suffix='.log')
COM2 = tempfile.mktemp(prefix='osprey-com2-', suffix='.sock')
COM2LOG = tempfile.mktemp(prefix='osprey-com2-', suffix='.out')

SETUP = [
 "9660srv -r -f /dev/sdF2/data cd9660 >[2]/dev/null & sleep 1; mkdir -p /n/cd; "
 "mount /srv/cd9660 /n/cd; rm -f /tmp/ring /tmp/pip; cp /n/cd/bin/ring /tmp/ring; cp /n/cd/bin/pip /tmp/pip; "
 "chmod +x /tmp/ring /tmp/pip",
 "bind '#O' /n/osprey; sz=`{grep arena /n/osprey/status | sed 's/.*slice //; s/ .*//'}; "
 "for(c in 1 2) { echo create $c 40000000 800000000 200000000 >/n/osprey/ctl; "
 "echo attach $c 0 >/n/osprey/ctl; echo limit $c 262144 65536 64 >/n/osprey/ctl }; echo ready",
]

# each is (what it proves, the commands to run, what must come back).
# a command is kept short: a long line is wrapped by the console and a
# character of it goes missing, which looks exactly like a bug in the
# thing being checked.
CHECKS = [
 ("a request answered with nobody writing service",
  ["echo serve 1 >/n/osprey/ctl; /tmp/ring osprey0 $sz poll"],
  "reply poll done"),
 ("a second one, through the same mapped ring",
  ["/tmp/ring osprey0 $sz alloc 4096"],
  "reply alloc done 4096"),
 ("a select woken by a semaphore, on the arm that was given",
  ["{ /tmp/ring osprey1 $sz wait 3 & }; sleep 2; echo semup 2 3 >/n/osprey/ctl",
   "sleep 2; echo waited"],
  "select returned, arm 1"),
 ("a page handed from one container to another, mapped and not copied",
  ["echo page 1 alloc >/n/osprey/ctl",
   "/tmp/ring osprey0 $sz page ospreypage0 'handed over'",
   "echo flip 1 2 0 >/n/osprey/ctl",
   "/tmp/ring osprey1 $sz page ospreypage0"],
  "holds 'handed over'"),
 ("a private name",
  ["echo bind 1 here /n/osprey >/n/osprey/ctl",
   "grep '^name 1' /n/osprey/status"],
  "name 1 here /n/osprey"),
 ("a request still in flight, and the buffer it names, across a checkpoint",
  ["echo create 7 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 7 0 >/n/osprey/ctl; echo poke 7 0 /dev/osversion >/n/osprey/ctl",
   "echo submit 7 open 0 0 >/n/osprey/ctl; cp /n/osprey/snap /tmp/s",
   "echo exit 7 >/n/osprey/ctl; cp /tmp/s /n/osprey/snap",
   "echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "7 open done"),
 ("and the file that open returned, read through it",
  ["echo submit 7 read 0 64 32 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 1; o=`{awk '/^proc 7/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+64}' /n/osprey/status}",
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 4 >[2]/dev/null; echo"],
  "2000"),
 ("an attribute written over pi-p, seen by the fid that wrote it",
  ["echo limit 1 262144 65536 64 >/n/osprey/ctl",
   "x=`{/tmp/pip open 1 /1 write 1 packetmax 55 read 1 packetmax}; echo $x"],
  "'55'"),
 ("and by nobody else until that fid is closed",
  ["/tmp/pip open 2 /1 read 2 packetmax close 2"],
  "'64'"),
 ("and by everybody after it",
  ["/tmp/pip -s $x(5) close 1",
   "/tmp/pip open 3 /1 read 3 packetmax close 3"],
  "'55'"),
 ("an operation the kernel refuses put on another container's ring",
  ["for(c in 8 9) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "for(c in 8 9) echo attach $c 0 >/n/osprey/ctl",
   "echo delegate 8 9 >/n/osprey/ctl",
   "echo submit 8 send 7 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   # rc reads a bare name= as an assignment, so awk -v is spelled out
   "sl=`{grep '^proc 9' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
   "sg=osprey^`{echo $sl $sz | awk '{print int($1/$2)}'}; echo $sg",
   "/tmp/ring $sg $sz wait 0 get:0"],
  "message op 5 from 8"),
 ("answered there and routed home",
  ["/tmp/ring $sg $sz wait 0 put:1",
   "echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "8 send done 7"),
 ("a round trip that does not wait for the clock",
  ["{echo '1 2000' >[1=0]; cat} <>/n/osprey/bench"],
  None),   # checked by the number, not by a string
 ("four hundred round trips through the mapped ring with no trap at all",
  ["time /tmp/ring osprey0 $sz bench 400"],
  None2),
 ("a uart driven by a task, answering a control message",
  ["echo create 5 100000000 200000000 200000000 >/n/osprey/ctl",
   "echo attach 5 0 >/n/osprey/ctl; echo uart 5 eia1 3 >/n/osprey/ctl",
   "echo 'osprey uart task' >/tmp/t",
   "o=`{awk '/^proc 5/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+256}' /n/osprey/status}",
   "dd -if /tmp/t -of /n/osprey/arena -bs 1 -oseek $o -count 17 >[2]/dev/null",
   "echo output 5 256 17 >/n/osprey/ctl; sleep 2",
   "echo submit 5 close 0 >/n/osprey/ctl; sleep 2; cat /n/osprey/reply"],
  "5 close done"),
 ("sixteen hundred requests from eight processes at once, none lost",
  ["for(c in 11 12 13 14 15 16 17 18) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 11 0 >/n/osprey/ctl; echo attach 12 1 >/n/osprey/ctl",
   "echo attach 13 2 >/n/osprey/ctl; echo attach 14 3 >/n/osprey/ctl",
   "echo attach 15 0 >/n/osprey/ctl; echo attach 16 1 >/n/osprey/ctl",
   "echo attach 17 2 >/n/osprey/ctl; echo attach 18 3 >/n/osprey/ctl",
   "for(c in 11 12 13 14 15 16 17 18) echo limit $c 4194304 65536 64 >/n/osprey/ctl",
   "for(c in 11 12 13 14 15 16 17 18) echo serve $c >/n/osprey/ctl",
   "for(c in 11 12 13 14 15 16 17 18) { { for(i in `{seq 1 200}) "
   "echo submit $c alloc 4096 >/n/osprey/ctl } & }; echo launched",
   "sleep 25; grep '^proc 1[1-8] ' /n/osprey/status | "
   "sed 's/.*mem /mem /; s/ net.*//' | sort | uniq -c",
   "for(c in 11 12 13 14 15 16 17 18) echo exit $c >/n/osprey/ctl"],
  "8 mem 819200 of 4194304"),
 ("the pages a container held coming back when it exits",
  ["for(c in 31 32 33 34 35) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "for(c in 31 32 33 34 35) echo attach $c 0 >/n/osprey/ctl",
   "for(c in 31 32 33 34 35) for(i in 1 2 3 4 5 6) echo page $c alloc >/n/osprey/ctl",
   "for(c in 31 32 33 34 35) echo exit $c >/n/osprey/ctl",
   "echo create 36 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 36 0 >/n/osprey/ctl",
   "for(i in 1 2 3 4 5 6) echo page 36 alloc >/n/osprey/ctl",
   "grep '^pages 36' /n/osprey/status | awk '{print \"held\", NF-2}'",
   "echo exit 36 >/n/osprey/ctl"],
  "held 6"),
 ("eight idle service processes costing nothing at all",
  ["for(c in 21 22 23 24 25 26 27 28) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "for(c in 21 22 23 24 25 26 27 28) echo attach $c 0 >/n/osprey/ctl",
   "for(c in 21 22 23 24 25 26 27 28) echo serve $c >/n/osprey/ctl",
   "sleep 20; n=`{ps | grep ' osprey$' | awk '$3 != \"0:00\" || $4 != \"0:00\"' | wc -l}",
   "if(~ $n 0) echo 'none of them busy'; if(! ~ $n 0) echo $n busy",
   "for(c in 21 22 23 24 25 26 27 28) echo exit $c >/n/osprey/ctl"],
  "none of them busy"),
 ("a container held to its reservation",
  ["{ while(){} } &",
   "b=$apid; echo create 6 5000000 100000000 100000000 >/n/osprey/ctl",
   "echo attach 6 0 >/n/osprey/ctl; echo mode 6 strict >/n/osprey/ctl",
   "echo bindproc 6 $b >/n/osprey/ctl",
   "{ while(){} } &",
   "u=$apid; sleep 8; ps | awk '$2=='^$b"],
  "Stopped"),
 ("and one that is not, still running beside it",
  ["ps | awk '$2=='^$u",
   "echo kill >/proc/$b/ctl; echo kill >/proc/$u/ctl; echo done"],
  "!Stopped"),
 # last: reset takes the machine apart
 ("a session that outlived a reset told there is no such session",
  ["y=`{/tmp/pip open 1 /1 read 1 budget}; echo $y",
   "echo reset >/n/osprey/ctl",
   "/tmp/pip -s $y(5) read 1 budget"],
  "write failed: no session"),
]

def plain(s):
    return re.sub(r'\x1b\[[0-9;=?]*[a-zA-Z]', '', s)

def main():
    keep = '-k' in sys.argv[1:]
    # the reader outlives the run; it is stopped once the console is done
    reader = subprocess.Popen([sys.executable, 'scripts/osprey-com2read.py',
                               COM2, '600'],
                              stdout=open(COM2LOG, 'w'),
                              stderr=subprocess.DEVNULL)
    argv = ['./scripts/osprey-console.py', '-q', '-p', '4',
            '-2', 'unix:%s,server,nowait' % COM2, '-l', LOG, '-S',
            '-d', ROOT + '/.qemu/9front-root.qcow2', '-t', '320',
            '-e', r'user\[glenda\]: =', '-u', '% ']
    for c in SETUP:
        argv += ['-c', c]
    for i, (_, cmds, _) in enumerate(CHECKS):
        argv += ['-c', "echo '#### %d'" % i]
        for c in cmds:
            argv += ['-c', c]
    argv += ['-c', "echo '#### %d'" % len(CHECKS)]
    subprocess.run(argv, capture_output=True, text=True)
    time.sleep(2)
    reader.terminate()
    reader.wait()

    try:
        log = plain(open(LOG, errors='replace').read())
    except OSError:
        log = ''
    try:
        com2 = plain(open(COM2LOG, errors='replace').read())
    except OSError:
        com2 = ''

    # only what a check's own commands produced counts as its answer;
    # searching the whole log finds the text in an echoed command
    parts = {}
    for i in range(len(CHECKS)):
        a = log.find("#### %d\n" % i)
        b = log.find("#### %d\n" % (i+1))
        parts[i] = log[a:b] if a >= 0 and b > a else ''

    bad = 0
    for i, (what, _, want) in enumerate(CHECKS):
        if want is None2:
            # clock-bound would be 5.5ms each: over two seconds for four
            # hundred, where a server that stays awake takes hundredths
            m = re.search(r'(\d+\.\d+)r', parts[i])
            ok = ('did 400 round trips' in parts[i]
                  and m is not None and float(m.group(1)) < 1.0)
            if m:
                what += ' (%ss)' % m.group(1)
        elif want is None:
            # a round trip took a whole clock tick until something woke
            # the service process; anything near a millisecond is that
            # bug back again
            m = re.search(r'(\d+) ns each', parts[i])
            ok = m is not None and int(m.group(1)) < 1000000
            if m:
                what += ' (%s ns)' % m.group(1)
        elif want.startswith('!'):
            # what must not be there: a check that only ever looked for
            # something present would pass however the other half went
            ok = want[1:] not in parts[i]
        else:
            ok = want in parts[i]
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok:
            bad += 1
    # the uart's output leaves the machine rather than coming back to it
    ok = 'osprey uart task' in com2
    print('%-4s %s' % ('ok' if ok else 'FAIL',
                       'and the bytes it was given, out of the device'))
    if not ok:
        bad += 1

    if keep or bad:
        print('log %s' % LOG)
        print('second serial %s' % COM2LOG)
    else:
        for f in (LOG, COM2LOG):
            try:
                os.unlink(f)
            except OSError:
                pass
    return 1 if bad else 0

sys.exit(main())
