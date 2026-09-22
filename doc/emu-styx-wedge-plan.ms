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
.CW Qctl / Qdata
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
