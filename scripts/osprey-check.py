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
 "mount /srv/cd9660 /n/cd; echo mounted",
 # a long line loses a character to the console, so the copying is its own
 "for(b in ring pip p9srv o9cat fpbits) { rm -f /tmp/$b; cp /n/cd/bin/$b /tmp/$b; chmod +x /tmp/$b }",
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
 # every loader in the tree laid a double out as eight zero bytes on a
 # 64 bit host while the compilers' objects were right, so only a running
 # program could say: this one prints the bits of 1.5 and of 1.5+1.5
 ("a double in an Osprey command holding its value through the loader",
  ["/tmp/fpbits"],
  "3.0 4008000000000000"),
 # and the compiler: fdlibm scales a result by writing the high word of
 # a local double through a pointer, and 6c kept the double in a
 # register across the write and returned it unscaled -- 1.5 for what
 # should be 3.0 -- until its mkvar marked overlapping entries as
 # address-taken, as the other session's fix to jc and tc does
 ("and a double whose high word is written through a pointer, scaled",
  ["/tmp/fpbits | grep scale"],
  "scale 4008000000000000"),
 ("a file opened and read by a program that only uses the library",
  ["/tmp/o9cat osprey0 $sz /dev/osversion"],
  "arms intact, read"),
 # the talk says segments may be shared at different addresses, and
 # everything in the span is an offset rather than a pointer so that
 # they may; nothing until now attached one twice to find out.
 ("the same slice mapped a second time somewhere else, and worked there",
  ["/tmp/ring osprey0 $sz twice | sed 1d"],
  "through the second mapping, reply poll done"),
 ("a select woken by a semaphore, on the arm that was given",
  ["{ /tmp/ring osprey1 $sz wait 3 & }; sleep 2; echo semup 2 3 >/n/osprey/ctl",
   "sleep 2; echo waited"],
  "select returned, arm 1"),
 # the policy layer has had runtimeblock and runtimewake from the start
 # and nothing called either, so a container asleep in a select called
 # itself runnable however long it waited
 # waited for rather than slept for: how long a backgrounded program
 # takes to reach its select is not what is being measured, and a fixed
 # sleep made this fail about one run in four
 ("a container waiting in a select saying so",
  ["{ /tmp/ring osprey1 $sz wait 4 & }",
   "for(i in 1 2 3 4 5 6 7 8){ if(grep -s '^proc 2 core [0-9]* blocked' "
   "/n/osprey/status) break; sleep 1 }",
   "grep '^proc 2 ' /n/osprey/status | sed 's/proc 2 core [0-9]* /state /; s/ budget.*//'"],
  "state blocked"),
 ("and runnable again once it has been given what it waited for",
  ["echo semup 2 4 >/n/osprey/ctl",
   "for(i in 1 2 3 4 5 6 7 8){ if(grep -s '^proc 2 core [0-9]* runnable' "
   "/n/osprey/status) break; sleep 1 }",
   "grep '^proc 2 ' /n/osprey/status | sed 's/proc 2 core [0-9]* /state /; s/ budget.*//'"],
  "state runnable"),
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
 # semaphores are the microkernel's own state for a container and were
 # the one thing a checkpoint did not carry: a container that migrated
 # arrived having lost a wakeup it was owed
 ("a semaphore's count carried across a checkpoint with the container",
  ["echo create 21 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 21 0 >/n/osprey/ctl",
   "for(i in 1 2 3) echo semup 21 5 >/n/osprey/ctl",
   "cp /n/osprey/snap /tmp/s21; echo exit 21 >/n/osprey/ctl",
   "cp /tmp/s21 /n/osprey/snap; sleep 1",
   "grep '^sem 21 ' /n/osprey/status | awk '{print \"sem5\", $8}'"],
  "sem5 3/3/0"),
 ("and the data area it had written, though nothing was in its rings",
  ["echo create 22 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 22 0 >/n/osprey/ctl",
   "echo poke 22 64 carried-with-it >/n/osprey/ctl",
   "cp /n/osprey/snap /tmp/s22; echo exit 22 >/n/osprey/ctl",
   "cp /tmp/s22 /n/osprey/snap; sleep 1",
   "o=`{awk '/^proc 22/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+64}' /n/osprey/status}",
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 15 >[2]/dev/null; echo",
   "for(c in 21 22) echo exit $c >/n/osprey/ctl"],
  "carried-with-it"),
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
 # the two are on different cores on purpose: the talk's message passing
 # is between cores, and every other delegation here has both ends on
 # core 0, where nothing crosses.
 ("an operation the kernel refuses put on another container's ring, on "
  "another core",
  ["for(c in 8 9) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 8 0 >/n/osprey/ctl; echo attach 9 3 >/n/osprey/ctl",
   "grep -h '^proc [89] ' /n/osprey/status | sed 's/ state.*//'",
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
 ("a name space of the server's own, holding a name",
  ["rm -rf /tmp/only; mkdir -p /tmp/only /n/only",
   "echo p9srv-answered >/tmp/only/proof",
   "@{rfork n; bind /tmp/only /n/only; ls /n/only | awk 'END{print \"there\", NR}'} &",
   "sleep 2; echo asked"],
  "there 1"),
 ("and the one the kernel answers from, which has not got it",
  ["ls /n/only | awk 'END{print \"here\", NR}'"],
  "here 0"),
 ("a file opened by the personality server, in that name space",
  ["for(c in 61 62) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "for(c in 61 62) echo attach $c 0 >/n/osprey/ctl",
   "echo delegate 61 62 >/n/osprey/ctl",
   "s2=`{grep '^proc 62' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
   "sv=osprey^`{echo $s2 $sz | awk '{print int($1/$2)}'}; echo $sv",
   "@{rfork n; bind /tmp/only /n/only; /tmp/p9srv $sv $sz} &",
   "sleep 2; echo poke 61 0 /n/only/proof >/n/osprey/ctl",
   "echo submit 61 open 0 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "61 open done"),
 ("and what that file holds, read through it into the asking container",
  ["echo submit 61 read 0 512 32 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply",
   "o=`{awk '/^proc 61/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+512}' /n/osprey/status}",
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 14 >[2]/dev/null; echo"],
  "p9srv-answered"),
 ("and the same name refused to a container the kernel still answers for",
  ["echo create 63 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 63 0 >/n/osprey/ctl",
   "echo poke 63 0 /n/only/proof >/n/osprey/ctl",
   "echo submit 63 open 0 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 1; cat /n/osprey/reply"],
  "63 open error"),
 # the container's own name space, which is the policy layer's table and
 # not a Pgrp: bind is answered before anything is forwarded, so it is
 # the same answer whether a container has a server or not, and the
 # table is what a checkpoint carries.
 ("a name the container binds for itself, answered by the policy layer",
  ["echo poke 61 128 proof >/n/osprey/ctl",
   "echo poke 61 192 /n/only/proof >/n/osprey/ctl",
   "echo submit 61 bind 128 192 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "61 bind done"),
 ("and opened by that name and no other",
  ["echo submit 61 open 128 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "61 open done"),
 ("the shape of that file, asked of the personality",
  ["echo submit 61 stat 0 512 128 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply",
   "o=`{awk '/^proc 61/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+555}' /n/osprey/status}",
   # 9p puts the name 43 bytes into a stat entry, after its own length,
   # the type, the qid, the mode, the times and the length; what is
   # wanted is only that the entry names the file the server opened
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 5 >[2]/dev/null; echo"],
  "proof"),
 ("a second container binding the same name to something else",
  ["rm -rf /tmp/onlyb; mkdir -p /tmp/onlyb",
   "echo container-64-only >/tmp/onlyb/proof",
   "echo create 64 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 64 0 >/n/osprey/ctl; echo delegate 64 62 >/n/osprey/ctl",
   "echo poke 64 128 proof >/n/osprey/ctl",
   "echo poke 64 192 /tmp/onlyb/proof >/n/osprey/ctl",
   "echo submit 64 bind 128 192 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "64 bind done"),
 ("reading through that name what it bound and not what the other did",
  ["echo submit 64 open 128 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "echo submit 64 read 0 512 32 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "o=`{awk '/^proc 64/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+512}' /n/osprey/status}",
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 17 >[2]/dev/null; echo"],
  "container-64-only"),
 ("and the first one reading through the same name what it bound",
  ["echo submit 61 open 128 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "echo submit 61 read 2 640 32 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "o=`{awk '/^proc 61/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+640}' /n/osprey/status}",
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 14 >[2]/dev/null; echo"],
  "p9srv-answered"),
 # a server keeps a copy of a container's names, so the kernel has to say
 # when they change; without that word this reads the file it read before
 ("the same name bound again, and read as the file it now names",
  ["echo submit 61 close 2 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "echo poke 61 320 /tmp/onlyb/proof >/n/osprey/ctl",
   "echo submit 61 bind 128 320 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "echo submit 61 open 128 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "echo submit 61 read 2 704 32 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; echo service 4 >/n/osprey/ctl; sleep 1",
   "o=`{awk '/^proc 61/{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)+704}' /n/osprey/status}",
   "dd -if /n/osprey/arena -bs 1 -iseek $o -count 17 >[2]/dev/null; echo"],
  "container-64-only"),
 # and the same to a container with no server at all: naming is the
 # policy layer's, so it is answered the same way for everybody, which
 # is what it was not when it was a Pgrp a personality forked
 ("the same name bound by a container that has no server",
  ["echo poke 63 128 proof >/n/osprey/ctl",
   # /tmp/only and not /n/only: the name resolves either way, but what
   # the global name means is the answering personality's, and /n/only
   # is a name p9srv made in its own process and the kernel has not
   "echo poke 63 192 /tmp/only/proof >/n/osprey/ctl",
   "echo submit 63 bind 128 192 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 1; cat /n/osprey/reply"],
  "63 bind done"),
 ("and opened through it by the kernel's own personality",
  ["echo submit 63 open 128 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 1; cat /n/osprey/reply"],
  "63 open done"),
 # the same container, the same personality, a second name: what a
 # global name stands for is the answering personality's, and /n/only is
 # a name p9srv made in its own process and the kernel never saw
 ("and a second name of its own that this personality cannot reach",
  ["echo poke 63 256 hidden >/n/osprey/ctl",
   "echo poke 63 320 /n/only/proof >/n/osprey/ctl",
   "echo submit 63 bind 256 320 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 1; echo submit 63 open 256 0 >/n/osprey/ctl",
   "echo service 4 >/n/osprey/ctl; sleep 1; cat /n/osprey/reply"],
  "63 open error"),
 # a name in this table decides what an open opens, so half a name is
 # not a smaller answer but a different one
 ("a name too long for the table refused rather than cut short",
  ["echo poke 63 384 toolong >/n/osprey/ctl",
   "echo poke 63 448 /tmp/only/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/n/osprey/ctl",
   "echo submit 63 bind 384 448 0 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 1; cat /n/osprey/reply",
   "echo exit 63 >/n/osprey/ctl"],
  "63 bind error"),
 ("a process of the server's own for each container it answers for",
  ["sleep 1; ps | awk '/p9srv/{n++}END{print \"procs\", n+0}'"],
  "procs 3"),
 ("and one fewer when a container goes, without anything asking",
  ["echo exit 64 >/n/osprey/ctl; sleep 3",
   "ps | awk '/p9srv/{n++}END{print \"procs\", n+0}'",
   # give the slots back: there are only sixteen, and the check below
   # wants eight of them at once
   "for(c in 61 62) echo exit $c >/n/osprey/ctl"],
  "procs 2"),
 # the rule the man page called enforced but not demonstrated: every
 # container in this check is glenda's, so a server reaches a client's
 # slice as its owner would anyway.  auth/none gives a server of another
 # user, which is what the rule is for.
 ("a server run by another user reaching a container that delegated to it",
  ["for(c in 71 72 75) echo create $c 40000000 800000000 200000000 >/n/osprey/ctl",
   "for(c in 71 72 75) echo attach $c 0 >/n/osprey/ctl",
   "echo grant 72 none >/n/osprey/ctl; echo delegate 71 72 >/n/osprey/ctl",
   "s1=`{grep '^proc 71 ' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
   "g1=osprey^`{echo $s1 $sz | awk '{print int($1/$2)}'}; echo client $g1",
   # auth/none builds a name space of its own, in which /tmp is none's
   # rather than glenda's; the copy the server runs has to be somewhere
   # both users see.
   "cp /tmp/ring /usr/glenda/ring9; chmod 755 /usr/glenda/ring9",
   "auth/none /usr/glenda/ring9 $g1 $sz | sed 1q"],
  "mapped"),
 ("and refused the one that delegated to nobody",
  ["s5=`{grep '^proc 75 ' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
   "g5=osprey^`{echo $s5 $sz | awk '{print int($1/$2)}'}; echo other $g5",
   "auth/none /usr/glenda/ring9 $g5 $sz | sed 1q"],
  "segattach"),
 # the other half of the same rule: a container's memory is also for the
 # process bound to it and the processes that one started, which is how
 # a container reaches its own slice before anybody has been named.  The
 # container is glenda's and the process is none's, so nothing but the
 # parent chain can let it in.
 ("a process the container's own started, reaching it though it is not "
  "the container's user",
  # none writes nowhere glenda's home allows, so the two share a
  # directory made for it
  ["rm -rf /usr/glenda/nw; mkdir /usr/glenda/nw; chmod 777 /usr/glenda/nw",
   "echo '#!/bin/rc' >/usr/glenda/nonetry",
   "echo 'echo '^'$pid'^' >/usr/glenda/nw/pid' >>/usr/glenda/nonetry",
   "echo 'sleep 6' >>/usr/glenda/nonetry",
   "echo /usr/glenda/ring9 $g5 $sz '>[2=1] >/usr/glenda/nw/out' "
   ">>/usr/glenda/nonetry",
   "chmod 755 /usr/glenda/nonetry",
   "auth/none /usr/glenda/nonetry &",
   "sleep 2; echo bindproc 75 `{cat /usr/glenda/nw/pid} >/n/osprey/ctl",
   "sleep 9; sed 1q /usr/glenda/nw/out"],
  "mapped"),
 ("with the slots given back",
  ["for(c in 71 72 75) echo exit $c >/n/osprey/ctl; echo gone"],
  "gone"),
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
 ("the uart as a pi-p thing, the talk's slide 20: opened by its name, its attributes read by name",
  ["echo uart 5 eia1 3 >/n/osprey/ctl",
   "x=`{/tmp/pip open 4 /eia1 read 4 '*' read 4 b read 4 name}; echo $x"],
  "'* b d name'"),
 ("and its data written as an attribute, out through the driver task's output queue",
  ["/tmp/pip open 6 /eia1 write 6 d 'pip to the uart' close 6; sleep 2"],
  "!error"),
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
 # each count is waited for rather than read straight away: a kproc
 # takes a moment to start and a moment to finish, and reading the
 # number before it has is what made this fail about one run in four.
 # Waiting bounded still fails if the number never arrives, which is
 # what the check is actually about.
 ("the wire pi-p is spoken on given back when it is turned off",
  ["fn waitpip { for(i in 1 2 3 4 5 6 7 8){ "
   "if(~ `{ps|grep ospreypip|wc -l} $1) break; sleep 1 } }",
   "echo pipether ether0 on >/n/osprey/ctl; waitpip 2",
   "a=`{ps|grep ospreypip|wc -l}",
   "echo pipether ether0 off >/n/osprey/ctl; waitpip 0",
   "b=`{ps|grep ospreypip|wc -l}",
   "echo pipether ether0 on >/n/osprey/ctl; waitpip 2",
   "c=`{ps|grep ospreypip|wc -l}",
   "echo wire $a $b $c; echo pipether ether0 off >/n/osprey/ctl"],
  "wire 2 0 2"),
 # a server asks status for a container's slice precisely so as not to
 # believe the container's own map, so status must not be repeating what
 # it finds there.  Nothing is serviced between the scribble and the
 # read: a request being serviced puts the map back, which is what made
 # the first version of this line pass whether the bug was there or not.
 ("a scribbled map not moving where status says the data area is",
  ["echo create 41 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 41 0 >/n/osprey/ctl; echo limit 41 262144 65536 64 >/n/osprey/ctl",
   "sl=`{grep '^proc 41' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
   "d1=`{awk '/^proc 41 /{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)}' /n/osprey/status}",
   "dd -if /dev/random -of /n/osprey/arena -bs 1 -oseek $sl -count 320 >[2]/dev/null",
   "d2=`{awk '/^proc 41 /{for(i=1;i<=NF;i++)if($i==\"data\")print $(i+1)}' /n/osprey/status}",
   "if(~ $d1 $d2) echo unmoved $d2",
   "if(! ~ $d1 $d2) echo moved $d1 to $d2"],
  "unmoved"),
 ("and the container that did it not taking the machine with it",
  ["echo serve 41 >/n/osprey/ctl",
   "dd -if /dev/random -of /n/osprey/arena -bs 1 -oseek $sl -count 320 >[2]/dev/null",
   "echo submit 41 alloc 4096 >/n/osprey/ctl; echo service 4 >/n/osprey/ctl",
   "sleep 2; grep '^proc 41' /n/osprey/status | sed 's/.*mem /mem /; s/ net.*//'",
   "echo exit 41 >/n/osprey/ctl; echo still here"],
  "still here"),
 ("the span refusing a slice that is not the caller's",
  ["echo create 51 40000000 800000000 200000000 >/n/osprey/ctl",
   "echo attach 51 0 >/n/osprey/ctl",
   "cp /n/osprey/snap /tmp/s51",
   "sed 's/^owner glenda/owner bob/' /tmp/s51 >/tmp/s52",
   "cp /tmp/s52 /n/osprey/snap; grep '^owner 51' /n/osprey/status",
   "sl=`{grep '^proc 51' /n/osprey/status | sed 's/.*slice //; s/ .*//'}",
   "dd -if /n/osprey/arena -bs 1 -iseek $sl -count 8 >/dev/null"],
  "permission denied"),
 ("and a checkpoint refusing to write over one",
  ["cp /tmp/s51 /n/osprey/snap"],
  "permission denied"),
 # last: reset takes the machine apart
 ("a session that outlived a reset told there is no such session",
  ["y=`{/tmp/pip open 1 /1 read 1 budget}; echo $y",
   "echo reset >/n/osprey/ctl",
   "/tmp/pip -s $y(5) read 1 budget"],
  "write failed: no session"),
 # and after the reset every slot is free, which is when a checkpoint of
 # a whole machine can be asked for.  A container that has written its
 # whole data area is about nine and a third kilobytes of checkpoint,
 # since the data goes whatever the rings hold, so sixteen of them is
 # about a hundred and fifty: at the old Snaplen the eighth was refused.
 ("a checkpoint of every container the machine holds, none of them empty",
  ["w=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
   "fn fill { for(i in `{seq 0 60}) echo poke $1 "
   "`{echo $i 64 | awk '{print $1*$2}'} $w >/n/osprey/ctl }",
   "for(c in `{seq 1 16}) echo create $c 4000000 800000000 200000000 >/n/osprey/ctl",
   "for(c in `{seq 1 16}) echo attach $c 0 >/n/osprey/ctl",
   "for(c in `{seq 1 16}) fill $c",
   "echo held `{grep -c '^container ' /n/osprey/snap}"],
  "held 16"),
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
    argv = ['./scripts/osprey-console.py', '-q', '-b', '-p', '4', '-n', 'e1000',
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

    # only what a check's own commands produced counts as its answer.
    # The console echoes each command after its prompt, so a line that
    # begins with one is what was typed rather than what came back, and
    # an expected string that appears in the command would otherwise
    # always match -- which is a check that passes whatever the machine
    # does.  Two lines in this file were doing exactly that before the
    # echoes were dropped here.
    parts = {}
    for i in range(len(CHECKS)):
        a = log.find("#### %d\n" % i)
        b = log.find("#### %d\n" % (i+1))
        raw = log[a:b] if a >= 0 and b > a else ''
        # the commands themselves, taken out by what was typed rather
        # than by the prompt they follow: a background job's output
        # arrives on the same console line as the next prompt, and
        # dropping whole prompt lines dropped that too
        for c in CHECKS[i][1]:
            raw = raw.replace(c, '')
        parts[i] = raw

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
    ok = 'pip to the uart' in com2
    print('%-4s %s' % ('ok' if ok else 'FAIL',
                       'and the bytes written to its d attribute over pi-p, out of the device too'))
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
