.TL
Making the Raspberry Pi 3B stay up: what wedges it, and in what order to fix it
.AU
.PP
The board works and then stops.  Over two days it wedged five times, and
each time cost between ten minutes and an hour \(em a power cycle, and
twice the card carried to another machine and back.  This is a plan for
the wedging itself, written because throughput and drivers cannot be
worked on from a machine that has to be rescued by hand every half hour,
and because most of what was believed about these hangs turned out to be
wrong when it was finally measured.  Everything below that states a fact
was measured on the board on 19 or 20 September 2026 and says how.
." P1/P2 are Plan 9 troff additions and groff -ms does not define
." them: without this every .P1 block renders as FILLED PROSE, which
." is not an error so no lint catches it.  Checked by
." tests/troff-p1.sh.
.de P1
.DS L
..
.de P2
.DE
..
.NH 1
What the hang is not
.PP
Four explanations were held at various points and all four are dead.
They are listed because each cost time, and because the way each died is
the method the rest of this plan uses.
.IP 1.
.B "Not the network."
The board answers ping during the stall: three of three, 5.4ms average,
taken from the host at the moment a read of
.CW /n/remote
had been outstanding for two minutes.  The USB ethernet is alive and
carrying traffic while the machine is wedged.
.IP 2.
.B "Not the styx server on the host."
Mounted from the host itself \(em
.CW "mount -A tcp!127.0.0.1!6666 /n/x"
\(em it attaches and lists a directory immediately, while the board is
stuck on the same export.
.IP 3.
.B "Not the out-of-order RST."
.CW "out of order RST rcvd"
appears in the console log and looks like a connection the board failed
to tear down.  It is not:
.CW ip/tcp.c
prints that message and then calls
.CW "localclose(s, Econrefused)"
on the next line, so the connection is closed and a reader gets an
error.
.IP 4.
.B "Not emu's missing release barrier."
The host
.I emu
had exactly this signature and it was a
.CW unlock()
with no release barrier
.CW ( coherencefn
was only ever
.CW nofence ).
The board's
.CW unlock()
in
.CW port/taslock.c
calls
.CW coherence()
before clearing the key, and
.CW coherence()
on this board is
.CW "DSB $15" ,
a full barrier.  The same bug is not here.
.NH 1
What the hang is
.PP
.B "The Dis interpreter hand-off stops, and processes pile up behind it."
Caught with
.CW ^\e
at the moment of the stall rather than after recovery, which is what
made the difference \(em every earlier dump was of a board that had
already come back, and the stacks of a healthy machine are indis\%tin\%guish\%able
from a hung one if all you look at is that everything is asleep.
Counting states instead:
.P1
hung     38 processes:  Wakeme 21  Queueing 13  Ready 3  Running 1
healthy  17 processes:  Wakeme  9  Queueing  7            Running 1
.P2
.B "Three processes Ready and nobody running them"
is the whole of it.  Ready means on a run queue and runnable.  Queueing
means waiting on the interpreter's own hand-off queue.  Thirteen waiting
for the VM and three ready to use it, with none of them running, is a
scheduler that has stopped handing over \(em and
.CW trap.c
already describes this shape in its own comment about
.CW intrpreempt :
"^\e on a wedged board shows every process in
.CW acquire() ,
the Dis interpreter's hand-off queue, waiting for a VM that nobody is
running to release."
.PP
The process count is the other half: 38 against 17.  Work arrives,
nothing finishes, and the arrivals accumulate.  Whatever stops the
hand-off does not stop new processes being made.
.NH 1
The fixes, in order
.NH 2
1.  Make the hang survivable before making it rare
.PP
This comes first because everything else is measured from a board that
has to be recoverable, and because it is already half done.
.IP \(bu
.B "^R reboots from the console receive path" ,
done.  ^C kills what the console is running but deliberately spares the
group leader, and when the leader is itself stuck \(em in a mount whose
server has panicked \(em the console echoes and never runs another
command.  Writing
.CW /dev/sysctl
needs that same shell.  ^R takes the watchdog directly from the receive
path, which is the one piece still running.
.IP \(bu
.B "The kernel root carries its own tools" ,
done:
.CW cp ,
.CW cmp ,
.CW dd ,
.CW sleep ,
.CW mkdir ,
.CW rm ,
.CW fatstress ,
25KB.  Every check used to go through a styx mount, and that mount is
what truncated a kernel to 8192 bytes and then reported the copy
identical over the same dead channel.
.IP \(bu
.B "Still to do: a hang detector that dumps by itself."
.CW ^\e
has to be typed by somebody watching.  A kproc that notices no Dis
process has run for N seconds and dumps \(em the same
.CW kstackdump()
\(em would catch the hangs nobody is sitting in front of, and would put
the evidence in the console log where a later reader can find it.
.NH 2
2.  Find what stops the hand-off
.PP
The counters for this mostly exist;
.CW "echo sched >/dev/sysctl"
prints
.CW hzschedcalls ,
.CW reschedraised ,
.CW reschedtaken ,
.CW delayedscheds
and the run-queue waits.  What is missing is taking them
.I at
.I the
.I hang ,
which needs the detector above or a second console.
.IP 1.
Take
.CW SCHED-COUNTS
during a wedge.  Raised much larger than taken means the process
holding the processor is not the interpreter.  Both flat means nothing
is even asking.
.IP 2.
Name the holder.  A process in
.CW acquire()
is waiting for whoever has the VM to
.CW release()
it.  The dump prints
.CW up->text ,
which is set to "acquire" and "released" by exactly those two
functions, so a census of texts across the 38 says whether anybody
holds it at all \(em and if nobody does, the hand-off queue itself has
lost an entry, which is a different bug from a holder that will not let
go.
.IP 3.
Suspect the paths that block inside the interpreter.  A kproc in a C
loop is not preemptible by design and is written down as such; the SD
driver was the large one and now sleeps.  What remains is
.CW usbdwc 's
.CW chanwait ,
which the hung dump shows a process sitting in, and which is where the
ethernet lives.  It sleeps with a timeout, so it should not hang for
ever \(em but a timeout that fires and then loops is indistinguishable
from a hang at this resolution, and
.CW "usbdwc: ep3.1 re-armed after 2 s (1000 times)"
is on the console through every one of these.  That message has never
been chased and it is now the best lead.
.NH 2
3.  Stop the mount making every stall permanent
.PP
.CW devmnt.c
waits for a reply with
.CW "sleep(r->z, rpcattn, r)"
and no timeout, and
.CW m->rip
gates the mount so that one outstanding RPC holds every other user of
it.  That is Plan 9's design and it is defensible on a machine you can
interrupt; on this board it converts any stall into a permanent one.
Two things follow.
.IP \(bu
The board accumulates connections.  The host showed two established
sockets from it at once, one per
.CW mount ,
and
.CW kupdate 's
.CW unmountremote()
is the only thing that ever takes one down.  Mounting in a loop leaks a
connection and an exportfs on the far side each time.
.IP \(bu
Nothing on the board can break a hung mount.  ^C spares the shell, and
the shell is what is stuck.  A console key that closes a named mount,
or an
.CW unmount
that does not itself go through the mount, would turn a wedge into an
error message.
.NH 2
4.  Then the two bugs that are still open on their own terms
.PP
Both are written up in
.CW doc/raspi3b-completion-plan.ms
and neither is the hang.
.IP \(bu
.B "The stale kernel."
A file written through
.I dossrv
came back with the right length and its first 256KB holding the
previous file's content, and every check agreed it was fine because
every check read back through the same server.
.CW tests/dossrv-outside.sh
is the one that does not; it has ruled out the sequence, cluster
recycling and cache contention, and what is left is the medium.
.IP \(bu
.B "DMA."
Reads work and are byte-correct against a PIO read of the same region.
.PP
This entry used to say writes work raw and that only the filesystem
path fails.  Both were wrong, and wrong the same way: every raw test
used
.CW "bs=32768" ,
sixty-four blocks at a time, and the failure needs nine \(em
.I dossrv 's
transfer size.  With
.CW "bs=4608"
it reproduces on the raw device immediately, no file server involved.
Every experiment that "ruled out" size, repetition, sustained traffic
or mixed direction was run at the wrong transfer size and ruled out
nothing.
.PP
.B "The stall itself is not fixed."
A nine-block DMA write still stops after three blocks with the engine
waiting on a DREQ the controller has stopped raising, while that
controller's status says it has room.  Eliminated so far, each with
the intervention shown active in the dump: the stale eMMC interrupt
.CW ( dmaclearirq ),
stale DMA channel state
.CW ( dmareset ),
and the source buffer's page offset \(em all seven collected failures
were at offset 0x640, which turned out to be where
.I dossrv 's
buffer sits and not a cause: fifty nine-block transfers from that
exact offset are as clean as fifty from zero.
.PP
.B "It is no longer fatal, and that is what mattered for this plan."
The failure used to poison every subsequent write \(em the PIO retry
of the same block failed, and so did a plain PIO write to an unrelated
block afterwards \(em so one stall panicked
.I dossrv
and every write after it blocked for ever on a mount with no server.
That is the "hung board" this whole document is about.  The cause was
in the last line of the driver's own dump,
.CW "(engine still active)" :
.CW bioerror()
stopped the card and reset the controller and never touched the DMA
channel, which was left armed against the peripheral's DREQ.
Resetting one end of a handshake while the other end holds it cannot
work.  With
.CW dmachanreset()
called first, 640KB through
.I dossrv
with DMA on takes a stall at block 59395, recovers, and finishes, and
the server is still there afterwards.
.NH 1
How this gets judged
.PP
One number, taken the same way each time: how long the board runs, under
load, without needing a human.  Everything above is in service of that
and nothing above should be called done on the strength of an argument.
The load is
.CW fatstress
against the card and a repeated read of a styx mount, because those are
the two that have actually wedged it.
.PP
And one rule, which this port learned the expensive way and which
belongs at the end of the plan rather than the middle: a check that
reaches its answer through the path it is checking cannot fail.
.CW kupdate 's
verify,
.CW fatstress 's
read-back,
.CW fsck_msdos
and a hand-run
.CW cmp
all agreed about a kernel whose first 256KB were wrong, because all four
were the same check.  Two of the five wedges were diagnosed from dumps
of a board that had already recovered.  Measure from outside the thing
being measured, or do not bother.
