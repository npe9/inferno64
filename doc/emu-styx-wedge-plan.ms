.TL
Fixing emu's styx server wedge
.AU
.NH 1
What is wrong, and how much of it is measured
.PP
.B "The symptom."
An
.CW emu
serving a tree over styx
.P1
emu -r <worktree> sh -c "styxlisten -A 'tcp!*!6666' export /"
.P2
stops answering.  It keeps LISTENING, TCP connections to it still
complete, and no Styx message is ever answered again.  The Pi 3B's
.CW kupdate
hangs in its mount with no message at all, which is
indistinguishable from a hung board and cost most of a day before the
fault was located on the host.
.PP
.B "What is measured, not inferred."
From a
.CW sample
of the wedged process and from
.CW netstat :
.IP \(bu
every Dis thread is idle \(em seven in
.CW __psynch_cvwait
.CW ( osblock ),
one in
.CW __accept ,
the rest Cocoa.  No thread holds a lock and none is blocked reading a
socket.
.IP \(bu
the
.CW exslave
processes are in
.CW "Sleep(&exq.rwait, exwork)" ,
their normal idle state.  The file service is healthy; work never
arrives.
.IP \(bu
a fresh connection COMPLETES and sits unaccepted:
.CW "tcp4 127.0.0.1.6666 127.0.0.1.59357 ESTABLISHED"
against
.CW "*.6666 LISTEN" ,
while the one thread sits in
.CW accept() .
.IP \(bu
not descriptor exhaustion: 23 open files, limit 1048576.
.PP
So the server stops accepting.  Everything else follows from that.
.NH 1
The mechanism, from the code
.PP
Three facts in
.CW emu/port/devip.c
and
.CW emu/port/ipif-posix.c
compose into the bug.
.IP 1.
.B "The acceptor is not counted as a user of the conversation."
.CW ipopen() 's
.CW Qlisten
case does not touch
.CW cv->inuse .
It takes
.CW cv->listenq
and calls
.CW "so_accept(cv->sfd, ...)" ,
which blocks.  The
.I "open itself"
is the blocking accept.
.IP 2.
.B "A close can shut the listening socket while that accept is in
.B "flight."
.CW ipclose()
on the last
.CW "Qctl / Qdata"
channel calls
.CW closeconv() ,
which does
.P1
fd = cv->sfd;
cv->sfd = -1;
if(fd >= 0)
        so_close(fd);
.P2
It does not consult
.CW cv->listenq
and has no way to know an accept is pending on that descriptor.
.IP 3.
.B "so_close is a bare close(2)."
.CW "so_close(int sock) { close(sock); }"
\(em no
.CW shutdown() .
POSIX leaves the effect of closing a descriptor with a blocked
.CW accept()
on it undefined, and on BSD and macOS the blocked accept does
.I not
wake.  The descriptor NUMBER is freed immediately and the next
.CW so_socket()
\(em a data connection, say \(em gets it back.
.PP
.B "Put together:"
the acceptor blocks in
.CW accept(fd) ;
something closes the conversation; the listening socket is closed and
.CW fd
is recycled for an unrelated socket; the accept is now waiting on a
socket that will never receive a connection, for ever.  New
connections complete into the real listener's backlog with nobody to
take them.  That is precisely the state measured above, and it needs
no deadlock, no leak and no exhaustion to explain it.
.PP
.B "This part is inference and is labelled so."
The code above is read, not guessed; the composition is consistent
with every measurement; but the specific
.I trigger
\(em which close drives
.CW cv->inuse
to zero while styxlisten is accepting \(em has not been caught in the
act.  Phase 1 exists to catch it.
.PP
.B "And it explains the failed reproduction."
A 9P client on the host could not wedge the server with reads of the
same 1.9MB file, four concurrent readers, resets mid-read, or
create-then-write.  None of those closes the ANNOUNCE conversation
while an accept is pending; they only ever touch connections already
accepted.  The board does, because its mounts come and go.
.NH 1
The plan
.NH 2
Phase 0 \(em a reproducer that runs in seconds
.PP
The one thing missing is a way to provoke this without the board.
From the mechanism it should be three lines of Limbo under a hosted
emu: announce a port, spawn a process that opens
.CW /net/tcp/N/listen ,
close the announce channel from the parent, then connect from outside
and see whether anything answers.  Run it in a loop with
.CW lsof
watching the descriptor numbers.
.PP
Acceptance: the wedge on demand, in under a second, with no Pi
attached.  Until that exists every later phase is being tested against
a fault that takes forty seconds and a board to produce.
.NH 2
Phase 1 \(em prove the trigger before changing anything
.PP
Instrument rather than assume:
.IP \(bu
a counter on
.CW Conv
of accepts in flight, incremented around
.CW so_accept ;
.IP \(bu
in
.CW closeconv() ,
print loudly when the socket is closed with that counter non-zero,
naming the descriptor;
.IP \(bu
log the descriptor returned by every
.CW so_socket()
and closed by every
.CW so_close() ,
so the recycle can be seen happening rather than argued for.
.PP
Acceptance: a run where the close-under-accept is printed and the same
descriptor number is then handed to a new socket.  If that never
appears, the mechanism above is wrong and the plan restarts from the
measurements, which stand on their own.
.NH 2
Phase 2 \(em the fix, in two independent parts
.PP
.B "Part A: count the acceptor."
Increment
.CW cv->inuse
before
.CW so_accept
and decrement after, including on the error path, so a conversation
cannot be torn down while an accept is in flight.  This is the correct
fix: it removes the window rather than coping with it.  The cost is
that a conversation with a pending accept lingers until the accept
returns, which is the right behaviour for a listening socket.
.PP
.B "Part B: make close wake the accept anyway."
Have
.CW so_close()
do
.CW "shutdown(sock, SHUT_RDWR)"
before
.CW close(sock) .
On macOS and the BSDs that wakes a blocked
.CW accept() ,
which then fails, unwinds through the existing
.CW waserror()
in the
.CW Qlisten
path, and releases
.CW listenq
cleanly.  This is defence in depth for every other place a descriptor
might be closed under a blocking call, and it is three lines.
.PP
Both, not either.  Part A stops the situation arising; part B stops it
being fatal when some other path arranges it.  Neither is a reason to
skip the other \(em which is the same judgement made about the two
halves of the raspi3b warm-restart fix.
.NH 2
Phase 3 \(em verify, and leave a regression test
.IP \(bu
Phase 0's reproducer must stop reproducing.
.IP \(bu
The board must complete a full
.CW kupdate
\(em 1.9MB fetched, verified and installed \(em which has succeeded
once all day.  Repeat it five times, because once is not a rate.
.IP \(bu
Leave the reproducer in
.CW tests/
so the next person finds it before finding the bug again.
.NH 1
Risks, and what would falsify this
.IP \(bu
.B "Part A could hold a conversation open for ever."
A listening socket with no connection coming keeps
.CW inuse
above zero, so the conv is never reclaimed.  That is already true of
any blocked acceptor and is what a listener is for, but it wants
checking against
.CW styxlisten 's
shutdown path.
.IP \(bu
.B "shutdown() on a listening socket is not universally specified."
It wakes the accept on BSD and macOS.  On Linux it returns ENOTCONN
for a listener and may not wake it, so part B must not be relied on
alone there \(em another reason part A is the real fix.
.IP \(bu
.B "The trigger may not be a close at all."
If Phase 1 never catches a close under a pending accept, the
composition is wrong.  The measurements in section 1 survive that; the
mechanism in section 2 does not.  In that case the next thing to
examine is whether
.CW so_accept
can return a descriptor that
.CW protoclone
then refuses \(em
.CW "nc == 0"
closes it and errors, and whether that path can be entered often
enough to matter.
.NH 1
Phase 1 results: both suspects dead, and a confound in the method
.PP
.B "The instrumentation."
.CW emu/port/devip.c
now reports, unconditionally because each is rare and each is the kind
of thing worth never missing: a socket closed while an accept is in
flight on it
.CW ( "CLOSE UNDER ACCEPT" ),
a
.CW protoclone
that runs out of conversations, an accepted connection refused for want
of one, a
.CW "Qdata / Qctl"
open refused on permissions, and every successful accept with its
descriptor and conversation.  Per-socket tracing of
.CW so_socket
and
.CW so_close
sits behind
.CW ipsockdebug ,
off by default.
.PP
.B "Both hypotheses are falsified."
Across wedges provoked by the board in twenty seconds:
.IP \(bu
.B "no CLOSE UNDER ACCEPT,"
ever.  The mechanism this plan was built around \(em a listening
descriptor closed under a blocked accept and its number reused \(em
does not happen.
.IP \(bu
no conversation exhaustion and no refused accept.  MAXCONV is 4096 and
the server never grew past its initial allocation.
.IP \(bu
no permission refusal on the accepted connection's data or ctl file.
.IP \(bu
.B "exactly one accept, ever:"
.CW "accepted fd 4 as conv 1, owner inferno" ,
which was served correctly.  Nothing after it.
.PP
Also eliminated on inspection rather than by measurement:
.CW protoclone 's
locking is balanced \(em every path, including both
.CW newconv
paths, returns with
.CW c->l
held and the single trailing
.CW qunlock
matches \(em and
.CW so_bind
sets
.CW SO_REUSEADDR
only, not
.CW SO_REUSEPORT ,
so two sockets cannot both be bound and listening on the port with the
kernel dividing connections between them.
.NH 2
The observation that changes the shape of the problem
.PP
In the last run the server did not wedge: it
.B exited .
Connections were refused, nothing was listening at all, and the log
stopped after the single accept with no error, no panic and no
diagnostic.  That is not the same failure as the one sampled earlier,
where the process was alive with a thread in
.CW __accept
and a completed connection sitting unaccepted in the backlog.
.PP
.B "Which means the method has a confound, and it is mine."
Several
.CW emu
instances were started and killed over the session.  A stale one can
hold the port while the instance being probed has exited, so
"the server is wedged, and here is a sample of it" may in some cases
have been a sample of a
.I different
process from the one refusing to answer.  Every conclusion above that
rests on a sample rather than on the
.CW ipdebug
log should be treated as provisional until it is repeated with exactly
one instance running and its pid pinned.
.NH 2
What the next session should do first
.IP 1.
Pin the pid.  Start one server, record its pid, and make every probe,
sample and
.CW lsof
assert that pid.  Refuse to draw a conclusion if a second
.CW emu
exists.
.IP 2.
Find out why it exits.  A silent exit after one connection is a
stronger lead than the wedge, because a process that dies leaves a
reason somewhere: run it in the foreground, check for a Dis exception
reaching the top, and see whether
.CW styxlisten 's
.CW listener()
\(em which calls
.CW error()
on a failed
.CW listen ,
and which silently ignores a nil return from
.CW "dial->accept" ,
leaving the connection open and unserved \(em is the process that
dies.
.IP 3.
Only then return to the blocked-accept observation, with one pid, and
settle whether it is real.
.NH 1
The instrument was wrong, and most of the wedges were not wedges
.PP
.B "The health check gave up after five seconds."
That is not long enough.  A server busy handing the board a 1.9MB
kernel does not answer a
.I new
connection promptly, and the check reported every such moment as
"WEDGED".  Measured, with the timeout raised:
.P1
styxd: answered after 6.6s (slow, not dead)
.P2
and a server declared wedged minutes earlier answered normally when
asked again.  So a large part of what this document calls a wedge is
the detector timing out on a busy server.
.PP
.B "What survives the correction."
.IP \(bu
The
.I first
wedge is real: a server up three and a half days that never answered a
Styx message across repeated tries, and a restart cured it.
.IP \(bu
The
.CW ipdebug
log is real evidence, because it records what the server actually did
rather than what a probe concluded: one accept, one data open, nothing
after.
.IP \(bu
.CW "styxlisten: cannot announce ... Address already in use"
is real and is its own fault, distinct from any wedge: after a kill,
a connection the previous instance accepted and never served sits in
CLOSE_WAIT holding the address, styxlisten fails to announce, and emu
stays up regardless because the shell runs on to its sleep.  A live
emu, no listener, and no error unless stderr was kept.  That was
mistaken for a wedge repeatedly.
.IP \(bu
.CW kupdate
reporting
.CW Hangup
is real, but it happened when the server was
.I killed
\(em by the restart logic reacting to a false wedge.
.PP
.B "What does not survive."
Every "wedged after N seconds" in this session that rests on the
five-second probe, which is most of them.  The blocked-accept
observation \(em a thread in
.CW __accept
with a connection unaccepted in the backlog \(em was taken while a
second emu instance was running and is doubly suspect: wrong process,
and possibly just a busy one.
.PP
.B "The lesson, for the fourth time in this port."
A measuring apparatus that can fail quietly will be believed.  The
stale-kernel check, the marker in a saturated console buffer, the
banner count with no screen session, and now a five-second timeout on
a busy server: four instruments, four confident wrong answers, each
found only by checking the instrument rather than the result.  The
standing rule this suggests is to make every check report
.I how
it succeeded \(em the latency, the line it matched, the pid it asked
\(em so that a degenerate success is visible as one.
.NH 2
Where this leaves the emu question
.PP
Open, and smaller than it looked.  There is one confirmed instance of
a server that genuinely stopped answering, on a very long-lived
process, and no reproduction of it.  The
.CW ipdebug
instrumentation is in place for the next occurrence; the health check
is patient now and says how long an answer took; the restart waits for
the port and surfaces an announce failure instead of hiding it.  The
next real wedge will be met with instruments that do not lie, which is
more than this session started with.
.NH 1
The best evidence yet, with the instruments fixed
.PP
Everything above was taken with a five-second probe and sometimes with
two emu instances running.  This was not: one instance, started and
pinned by
.CW styxd.sh ,
and a probe that tries three times with a thirty-second timeout.
.PP
.B "The server stops reading."
With the board's kupdate in progress and the probe failing all three
tries \\(em ninety seconds \\(em the host shows:
.P1
tcp4  28  0  192.168.8.233.6666  192.168.8.105.54016  ESTABLISHED
tcp4  23  0  192.168.8.233.6666  192.168.8.105.65304  ESTABLISHED
.P2
Two connections from the board, both ESTABLISHED, both with bytes
sitting UNREAD in the server's receive queue \\(em 28 and 23.  That is
not a busy server and it is not a slow one: the data has arrived, the
kernel has it, and nothing in emu is taking it.  A restart cured it,
as it has every time.
.PP
.B "Why this reading is worth more than the earlier ones."
A timeout says only that no answer came within N seconds, and a busy
server can fail that honestly \\(em which is how most of this
document's earlier wedges turned out to be nothing.  Unread bytes in
the receive queue say something stronger and independent of any
timeout: the request is there and the server is not reading it.  This
is the first observation in the whole investigation that a slow server
cannot produce.
.PP
.B "What it does not yet say."
Whether the reader for those connections died, never started, or is
blocked elsewhere.  The instrumentation in
.CW devip.c
reports accepts and opens; it says nothing about the export's read
loop.  The next step is to instrument that \\(em or simply to sample
the process while it is in this state, with the pid pinned, and look
for a thread in the export's reader rather than in
.CW __accept .
.NH 1
There is no wedge.  There is a 48-second tail.
.PP
.B "Fifteen connections, all answered."
One pinned emu, the board working the same server, a 60-second
timeout, and the latency recorded rather than thresholded:
.P1
probe  1: 23.68s   probe  6:  0.20s   probe 11:  0.00s
probe  2:  0.00s   probe  7:  0.40s   probe 12:  0.24s
probe  3:  1.60s   probe  8: 47.90s   probe 13:  0.35s
probe  4: 12.63s   probe  9: 10.05s   probe 14:  1.85s
probe  5:  0.00s   probe 10:  0.35s   probe 15:  4.63s

min 0.00s  median 0.40s  max 47.90s  over 15 answered
.P2
And the server's own log for the same run: 16 accepts, 16 data opens,
0 accept failures.  Nothing was dropped, nothing was left unserved,
nothing wedged.
.PP
.B "So every wedge in this document was a timeout shorter than that
.B "tail."
A median of 0.4s with a maximum of 48s is a distribution that any
fixed threshold will misread: at five seconds it looks like a server
that dies and revives, which is exactly the story this investigation
told itself for a day.  The unread bytes in the receive queue were
real, and they were a connection waiting its turn rather than one
nobody would ever serve.  The
.CW Hangup
kupdate reported was the restart logic killing a slow server.
.PP
.B "The real question, which is a better one."
Why does emu sometimes take tens of seconds to accept a new connection
while serving an existing one?  That is a fairness problem in the
scheduler or in exportfs's slave dispatch, it is reproducible, it is
measurable as a distribution, and it explains everything this document
has been chasing under a different name.  None of the code changes
made along the way are wasted \(em the instrumentation, the patient
handshake, the port wait, the announce-failure reporting all stand \(em
but the thing to fix is a latency tail, not a hang.
.PP
.B "And the lesson, which is the same one for the fifth time."
Measure the distribution, not the threshold.  Every instrument in this
investigation that reported a boolean \(em wedged or not \(em was
wrong, and the one that reported a number was right immediately.
