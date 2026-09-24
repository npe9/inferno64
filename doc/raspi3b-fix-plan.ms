.TL
What is left, in the order it has to be done
.AU
.PP
A consolidated plan across the Pi 3B port, its host server and the
branches that share them.  Written after a day in which five real bugs
were fixed, four attempted fixes were measured worse and reverted, and
five confident conclusions had to be withdrawn \(em so the method comes
first, because it is what the rest depends on.
.NH 1
The rules, which were paid for
.PP
Each of these was learned by getting it wrong, in this work, on the
record.
.IP 1.
.B "Repeat before reporting."
Five conclusions died on their second sample: "100% loss at eleven
frames", "a single connection reading kernel8.img kills the server",
"transmit is the expensive direction", "the pool made the board three
times faster", and "delprog blocks holding the VM".  A single
measurement is a hypothesis.
.IP 2.
.B "Quote the minimum, not the average."
The minimum round trip is stable to a tenth of a millisecond across
rounds; the average of the same measurements moved by six times in an
afternoon.  Distributions, or nothing.
.IP 3.
.B "Health-check before measuring, and refuse to report if it fails."
Two conclusions came from runs against a server that was already dead.
.CW netbench
and
.CW styxstress
now refuse; anything new must too.
.IP 4.
.B "Read the sample counts, not just the stacks."
Twice a stack occupying a tenth of a sampling window was read as a root
cause.  A stuck thread shows the whole window.
.IP 5.
.B "One variable."
Two of the four failed fixes were evaluated with another change still in
the tree.
.IP 6.
.B "Turn the traces off before believing a number."
A server left with
.CW INFERNO_MNTDEBUG
is thirty times slower and looks exactly like the fault the tracing
exists to find.
.IP 7.
.B "An instrument that cannot see must say so."
Not return a value.  Every harness here refuses rather than guesses.
.NH 1
Where it stands
.PP
.B "Fixed and verified on the host server:"
the flushed request answered twice; the fs->work registration race;
.CW mntfree
retiring an abandoned rpc's tag;
.CW mntralloc
leaving
.CW m
uninitialised;
.CW exflushed
returning while holding
.CW fs->l ;
.CW trapUSR1
leaving
.CW intwait
set for kprocs; and
.CW acquire()
waking the idle VM thread only when it queued first.  The last two are
on
.CW multicore
as well.
.PP
.B "Fixed and verified on the board:"
the SD retry path (FIFO errors retried, CMD12 before re-issue, a clock
instead of a spin count); dossrv returning an error rather than
panicking on a short read, and not dropping the device with it; bad
clusters marked and never allocated; the kernel update as a shell
script that cannot destroy a working kernel.
.PP
.B "Open, in dependency order."
Everything below is ordered by what blocks what, not by interest.
.NH 1
1. The server wedge.  Blocks everything else
.PP
Nothing else on this list can be measured while the server stops
answering after two connections, because every board measurement goes
through it.  This is first for that reason alone.
.PP
.B "What is known."
It reproduces in thirty seconds of board traffic.  With
.CW INFERNO_IPDEBUG=1
the healthy cycle repeats verbatim, and every connection is given the
SAME conversation and the SAME descriptor because both are freed and
immediately reused; the old descriptor is closed AFTER the next accept
has begun.  On the third connection there is no "accept returns" line
and none afterwards, with the listener genuinely in
.CW __accept
on fd 3, emu owning fd 3 and nothing else, and connections on the port
holding unread bytes and owned by no process.
.PP
.B "Step 1 \(em make the interleaving readable."
The log is written by several processes and its line order is not their
event order.  Give every devip accept and close a sequence number, and
record for each accept the descriptor it was CALLED with as well as the
one it returned.  The question is exactly whether the descriptor the
listener is blocked on is still the one bound to the port.
.PP
.B "Step 2 \(em falsify or confirm the recycle race."
If the listener is blocked on a descriptor that was closed and reissued,
that is the bug and the fix is to stop reusing a descriptor while an
accept on it is in flight.  If it is blocked on the right descriptor
with a connection pending, the fault is below emu and the next question
is the socket's state from the OS side.
.PP
.B "Acceptance:"
two hundred board poll cycles with no wedge, and
.CW styxabrupt.py
surviving 2000.
.NH 1
2. multicore dies after 1150-2000 abrupt disconnects
.PP
Same class, different branch, and now much further along: the four fixes
there took it from ~10 to ~1150-2000, with one clean run of 2000.  It
was not chased further.  It should be done with the same instruments and
AFTER item 1, because the two are likely the same remaining bug and
fixing it once is cheaper than twice.
.NH 1
3. The board's network: 6.4ms a frame
.PP
.B "Blocked on item 1"
\(em the counters that answer it live on the board and report through the
server.
.PP
.B "What is known."
A round trip carrying one Ethernet frame costs 6.4ms and each additional
frame about 4.6ms, both stable across rounds.  One 8KB Styx message is
six frames.  Reading the code says why:
.CW txproc
takes ONE frame off the queue and writes it to the bulk-out endpoint
with its own header and its own completion wait, while receive packs up
to 18.9KB into a single transfer.  Six frames out is six USB transfers.
.PP
.B "Step 1 \(em read the counters."
.CW etherusb
now counts bulk-in and bulk-out transfers and frames separately into
.CW /net.alt/ether/stats .
Sample them either side of a fixed workload and compute frames per
transfer in each direction.  If transmit is one frame per transfer and
receive is six or more, the reading above is confirmed and the direction
is settled \(em which is phase 1 of
.CW doc/raspi3b-net-plan.ms ,
still open because four samples disagreed with the next four.
.PP
.B "Step 2 \(em batch transmit, if the counters say so."
Several queued frames into one USB transfer, the way the receive side
already works.  Falsified if frames per transfer rises and the
8000-byte minimum does not fall.
.PP
.B "Do not repeat:"
64KB Styx messages (ls returned "stat buffer too small"); rxproc backoff
with a yield (ping better, real work twice as slow); the same with a 1ms
sleep (within noise, one run in three took 200s); four receive transfers
posted concurrently (worst of the four \(em the SMSC bulk-in stream is a
packed sequence of status-prefixed frames per transfer and concurrent
transfers do not survive it).
.PP
.B "Acceptance:"
1MB read median across two boots at least three times better than the
baseline
.CW netbench
establishes, with the one-frame ping minimum no worse than 6.4ms.
.NH 1
4. DMA paired with multi-block returns wrong data
.PP
The one SD failure that reproduces identically on the good card and the
bad one, so it is genuinely the driver.  DMA is off by default and PIO
at 64 blocks a command is fast, so this is real but not urgent.  It has
its own section in
.CW doc/raspi3b-completion-plan.ms .
.NH 1
5. Smaller, and independent of the above
.IP \(bu
.CW mv
raises "permission denied" on the board although
.CW /dis/mv.dis
is present, readable, the right size and works under the host emu.  The
update uses
.CW cp
and a verify instead.  Unexplained, and the only reason it matters is
that a rename is the atomic way to install a kernel.
.IP \(bu
"SD-FS skipped: no room below the first partition at 2048" \(em the new
card's FAT partition starts lower than the old one's, so the kfs test
area no longer fits.  Move it or shrink it.
.IP \(bu
The stall detector's
.CW holder
field is racy: it is cleared only if it still names the caller, so a
stale pointer survives a close handoff.  It is a hint, not evidence, and
the comment says so.  Either make it exact under the lock or drop it.
.IP \(bu
The console.  The rig has lost its screen session repeatedly and another
session has taken it mid-measurement.
.CW boot.sh
and
.CW netbench
both fall back to JTAG now, which is strictly better than what they
replaced; anything else that needs the console should do the same.
.NH 1
What NOT to do next
.PP
.B "Do not adopt parallelvm to fix the wedge."
It was tested, by serving this worktree with the multicore binary \(em no
merge, one command.  It wedges identically and the discriminator reads
0% CPU, so nothing is being starved of the VM.  parallelvm matters for
CONCURRENCY, which is where a server pool would pay, and not for this.
.PP
.B "Do not default to the connection pool."
.CW "styxlisten -P n"
is bounded and correct and helps nothing once the VM is parallel and the
two scheduler bugs are gone \(em shared measured identically at 0.01s.  On
a serial VM it is actively worse.  It stays a flag.
.PP
.B "Do not tune the rxproc sleep again."
Three variants, three regressions.
.NH 1
REVISION: item 1 is closed, and it was not any of the suspects
.PP
The server never wedged.  macOS App Nap was SUSPENDING the process:
.CW emu
links Cocoa and creates an
.CW NSApplication
even with no window on screen, and macOS suspends the whole task.  The
tell was in every sample from the start \(em watchdog kprocs whose only
job is a three-second
.CW nanosleep
had not fired for three and a half minutes.  Nothing inside a process
can stop an independent timer.
.PP
Fixed twice, deliberately: an activity declaration in
.CW main-cocoa.m
(hardening, since the GUI binary is sometimes run headless), and a
second build,
.CW emu-cpu ,
that links no Cocoa at all and is what
.CW styxd.sh
now serves with.  A process with no
.CW NSApplication
cannot be napped, which beats asking not to be.
.P1
emu-cocoa before   11 runs, 11 failures at 11..115 disconnects
emu-cocoa + activity 4 runs, 0 failures, 400 each
emu-cpu, no Cocoa   1 run,  0 failures, 400, queue 0/0/128
.P2
.PP
.B "And item 3 is unblocked and already half answered."
With a server that does not freeze, the board reads its own 1.955MB
kernel over Styx in 3.909, 3.933, 3.971 and 3.972 seconds \(em
.B "481 KB/s, 1MB in 2.1s" ,
timed by the board's own clock with the units proved by a five-second
calibration that measured 5.022s.  The figure this plan was written
against was thirty seconds a megabyte.
.NH 1
What is left, in order, after that
.IP 1.
.B "Close item 1 formally."
Its stated acceptance is styxabrupt surviving 2000.  Five runs of 400
have passed; run the 2000.
.IP 2.
.B "Item 3 step 1: read the ether counters."
.CW etherusb
counts bulk-in and bulk-out transfers and frames separately into
.CW /net.alt/ether/stats .
Sample either side of a fixed workload and compute frames per transfer
each way.  If transmit is one frame per transfer and receive is six or
more, the direction is settled and step 2 is batching transmit.
.IP 3.
.B "Item 5's small ones."
The racy
.CW holder
field is ours and should be made exact or dropped;
.CW mv
on the board; the kfs test area that no longer fits the new card.
.IP 4.
.B "Item 4: DMA with multi-block returns wrong data."
Real, reproduces on both cards, not urgent because DMA is off by default
and PIO at 64 blocks is fast.
.IP 5.
.B "Item 2: multicore."
Its emu is a Cocoa binary too, and it was being load-tested headless in
exactly the way that triggers this.  Re-test it with
.CW emu-cpu
BEFORE chasing anything there: the 1150-2000 figure may be this same
fault and nothing else.
.NH 1
Where it stands after the round-trip work
.PP
.B "Closed."
.IP \(bu
.I "The server wedge"
\(em macOS App Nap, suspending the whole emu.  Two fixes: an activity
declaration for the GUI binary, and
.CW emu-cpu ,
which links no Cocoa at all and is what
.CW styxd.sh
serves with.  Acceptance met: 2000 abrupt disconnects, worst health
0.040s.
.IP \(bu
.I "mv on the board"
\(em renaming on FAT through dossrv always failed with Eperm, because
rwstat compared a wstat's uid and gid literally and a wstat that means
to leave them alone sends nil.  mv falls back to copy-and-remove, so it
looked like it worked.  Proved with start-cluster numbers on a seeded
image.
.IP \(bu
.I "The kfs test area"
\(em it now uses the gap that exists rather than one that fitted the old
card, and checks the gap is empty before reaming it.  On this card it is
NOT empty, so the test is skipped for a correct reason and the check
earned its keep on the first boot.
.IP \(bu
.I "The racy holder field"
\(em handoffs and holder are written under isched.l now.
.IP \(bu
.I "The installer"
\(em install.sh could never have worked: it waits for a kupdate that was
deleted, and greps the console for a string the kernel does not print.
.CW tools/jtag/kinstall.sh
replaces it, drives the copy through the board.cmd poller, reboots with
.CW "echo reboot >/dev/sysctl"
because the console is handled but never hears, and confirms the banner.
End to end, unattended.
.PP
.B "The board's bulk read, measured end to end."
.P1
at the start of this work   ~30 s per MB
after the styx flush fix     3.9 s per 1.86MiB   (493 KB/s)
with read-ahead              2.76 s              (705 KB/s)
.P2
.PP
.B "What is left, in order."
.IP 1.
.I "More round trips in flight."
DONE and null.  The audit the comment demanded: the fid table is
correctly ref-counted under fs->fidlock, so the nil dereference it
blamed on two workers cannot come from there and was almost certainly
the double-reply bug fixed in 9d152e40.  One real hazard the comment did
NOT name: f->offset, c->uri and c->dri are read-modify-written without a
lock on DIRECTORY reads, which our client cannot presently provoke
because caching is files-only.  At 8 the server survived 2000 abrupt
disconnects with no fault, and the board measured 3.851s against 3.833s
at 4 \(em no difference.  Left at 4.
.IP 2.
.I "Bigger messages."
8KB msize is 239 requests for this file.  The blocker is GONE: "64KB
broke ls with stat buffer too small" was not ls and not a caller, it was
exportfs storing a 65551-byte buffer size in the ushort Fcall.nstat and
getting 15.  Clamped in 4075fb350, verified by the same ls at the same
msize.  Whether a bigger msize is faster is still unmeasured, and see
the note on this rig's variance before trying.
.IP 3.
.I "DMA with multi-block returns wrong data."
Untouched, reproduces on both cards, not urgent: DMA is off by default
and PIO at 64 blocks is fast.
.IP 4.
.I "multicore."
Its emu is a Cocoa binary and it was load-tested headless, which is
exactly the App Nap case.  Re-test with
.CW emu-cpu
BEFORE chasing anything: the 1150-2000 figure may be this and nothing
else.
.NH 1
Closing out: what is done and what is genuinely left
.PP
.B "Done, with a control that failed before and passed after."
The server wedge (App Nap;
.CW emu-cpu
links no Cocoa; 2000 abrupt disconnects clean).  mv on the board
(dossrv rejected every rename and mv silently copied instead; proved
with FAT start-cluster numbers).  "stat buffer too small" at 64K msize
(exportfs stored 65551 in a ushort and got 15).  The zero-length packet
after every transmitted frame.  The console flood from devmnt.  The kfs
test area.  The racy holder field.  The installer, which could never
have worked.
.PP
.B "Done, but weaker than that, and the commits say so."
.IP \(bu
.I "DMA with multi-block."
The code was moving one sector for an nthis-block command, proved with
a trace print \(em "DMA READ PATH nthis 64 len 512" against "sdhblc 64"
\(em and is now consistent with SDHBLC and with the PIO path.  But NO
user-visible corruption could be reproduced on this card, by four
different tests, so the recorded symptom stays unexplained and the write
path stays untested.  See 4b7abca76.
.IP \(bu
.I "Throughput."
2.8 s per MB, about eleven times better than this work began.  The
read-ahead and Maxconnproc questions are both unanswerable on this rig:
its variance between hours is larger than the effects, and that is
measured, not guessed.
.PP
.B "Left, and for whoever owns those branches."
.IP 1.
.I "multicore, dying after 1150-2000 abrupt disconnects."
Do NOT chase it before re-testing with a no-Cocoa emu.  That branch's
emu is a Cocoa binary and it was load-tested headless, which is exactly
the App Nap case that produced an identical signature here: connections
accepted, first message unread, CPU frozen, SIGTERM ignored, recovery
with no explanation.  Build
.CW "CONF=emu-cpu"
there and re-run before assuming there is a bug at all.
.IP 2.
.I "Why devsd masks a short DMA read."
Falling out of the DMA work and not chased: a 64-block command whose
DMA moved 512 bytes still delivered 32768 correct bytes to the caller.
Something above the driver is re-reading or re-filling.  Worth knowing,
because it means the SD layer's error reporting cannot presently be
trusted to surface a partial transfer.
.IP 3.
.I "The measurement rig."
Anything phrased "is X faster" needs ten or more readings per arm, arms
interleaved, each preceded by a reboot, distributions reported.  About
an hour of board time per question.  Deterministic questions \(em right
bytes or wrong bytes, survives or faults \(em cost minutes and are where
every fix in this document came from.
.NH 1
multicore: there is no bug there.  It was App Nap
.PP
Tested rather than assumed, because the note above said to.  The
multicore worktree, clean, its own
.CW styxlisten "export /" ,
the same styxabrupt load that produced "dies after 1150-2000 abrupt
disconnects", 3000 disconnects, two binaries built from the same head:
.P1
emu     (links Cocoa)     froze mid-run; cpu 0:02.29 -> 0:02.29 over 6s
emu-g   (links no Cocoa)  survived 3000, worst health 0.040s, cpu 4.29s
.P2
The Cocoa binary's freeze is the signature exactly: alive, answering
nothing, CPU not moving at all, no panic.  The no-Cocoa binary on the
same branch, same worktree, same load, does not do it.
.PP
.B "So the 1150-2000 figure measured macOS, not the parallel VM."
Every conclusion drawn from that number is suspect, and the four fixes
that took it from ~10 to ~1150 were measured the same way \(em they may
be real, they may be noise, and that has to be re-established before
any of them is trusted.
.PP
.B "What that branch needs."
A no-Cocoa build for serving, the way this one has
.CW emu-cpu .
.CW "mk CONF=emu-g install"
already produces one there; its checked-in binary was four days stale
against the head, which is its own trap \(em a stale no-Cocoa binary
tests old code and looks like a clean result.
.PP
The multicore worktree was left exactly as found: the rebuilt emu-g was
restored, nothing staged, nothing modified.
