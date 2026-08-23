.TL
Recording and Replaying an Inferno Session
.AU
Noah Evans
noah.evans@gmail.com
.AB
.PP
A program is easy to run again.
A
.I session
is not: it is a person typing and pointing at a screen, and when something goes
wrong in one there is usually nothing left to run.
.PP
This paper describes how a whole Inferno session is recorded and played back:
what is captured, at which layer, and what each layer can and cannot promise.
Three mechanisms are built on top of one another \(em a Styx trace, an input
recording, and a script \(em and they are deliberately not the same thing.
The last of them turns a recording into shell, which makes it readable,
editable, and stoppable, so that a replay can be interrupted and the machine
used before it carries on.
.PP
Rather more of the paper is about how the work was checked than about how it
works, because most of what went wrong looked exactly like success.
.AE
.NH
Introduction
.PP
Inferno is unusually well placed for this.
Its devices are files, so a session's dealings with the pointer, the keyboard,
the display and the clock all pass through one protocol, and interposing on
that protocol catches nearly everything without any of the programs involved
knowing.
.PP
Nearly.
The gap turns out to be the interesting part, and finding it took a
purpose-built program, because the failure it causes is an empty file rather
than an error.
.PP
Three layers ended up being necessary.
.IP \(bu
A Styx trace records what a program asked its name space for.
It is complete for a program, and blind to anything a program attaches for
itself.
.IP \(bu
An input recording sits below every bind, in the two functions every window
driver calls, and records what the host delivered.
It reproduces a session exactly and reads like nothing at all.
.IP \(bu
A script says what a person did.
It is approximate, and it is the only one you can stop in the middle.
.PP
Each is useful for something the others are not, and the temptation to present
them as one mechanism should be resisted; the man pages say outright that they
are not.
.NH
Recording the name space
.PP
.CW iostats
was already a Styx interposer: it forks a private name space, exports it over a
pipe, and sits in the middle, so that everything a program asks for passes
through it.
Its
.CW -d
option already printed every message.
.PP
Two things were missing.
Printing a message is not the same as keeping it \(em
.CW Tmsg.text
renders a read as
.CW "array[2167] of byte"
without the bytes \(em and although
.CW iostats
sampled
.CW /dev/time
on both sides of every message, it spent the result on latency statistics and
threw the times away.
.PP
.CW "iostats -t"
now writes each message verbatim with the time it crossed:
.DS I
.CW
'T' or 'R'   1 byte, the direction
time         8 bytes, big-endian microseconds
length       4 bytes, big-endian
message      length bytes, the Styx message
.R
.DE
Both readers hand records to a single writer, so the file is a total order and
no two processes share a file offset.
.PP
.CW styxreplay
serves such a trace back to a program.
Recording
.CW cat
of a file and replaying it produced output identical byte for byte over all
sixty-three exchanges.
A script that read, slept a second, read, slept two seconds and read again gave
a trace whose pauses came back as 1.005 and 2.002 seconds: each reply is held
for as long as it was originally held, which is what makes a recording of
somebody typing play back at the speed they typed.
.NH 2
Compare what a request asks for, not its bytes
.PP
The first version of
.CW styxreplay
compared messages byte by byte and reported a divergence on the very first
.CW attach ,
where the only difference was that the client had chosen fid 34 rather than
fid 23.
Tags and fids are the client's own bookkeeping and it is free to number them
differently on a second run.
.PP
What is worth comparing is what a request
.I asks
for: the path walked, the mode opened, the range read, the bytes written.
Divergence is then the useful output rather than an error, because it means
something outside the name space is affecting the program, and where it first
happens is exactly what one wants to know.
.PP
No fid translation table is needed either, which is the part worth
remembering: a reply never mentions a fid.
.CW Rwalk
and
.CW Ropen
carry qids, which are the server's names for things, and those come from the
trace.
.NH 2
Reading a trace as a session
.PP
A trace is a sequence of messages about numbered fids, which is the wrong
vocabulary for reading.
Nothing in it says that the program opened
.CW /dis/wm/toolbar.dis ;
it says that fid 12 was walked, and then opened.
.PP
Walks are what give fids their meaning, so
.CW styxlog
follows them, keeps a name for every fid, and reports opens and writes against
paths and times.
Loading a module is an open of its
.CW .dis
file, so the programs a session ran appear in the log, and so do the pauses
between them:
.DS I
.CW
    0.012  open   /tmpsh/sess.sh
    0.013  open   /dis/echo.dis
    0.014  write  /dev/null: hello\en
    0.016  open   /dis/sleep.dis
    1.018  open   /dis/date.dis
.R
.DE
.PP
Pending walks must be keyed by tag rather than held in one slot.
Several processes share one name space and one trace, so their walks
interleave, and a single slot binds one process's reply to another's path
while leaving the second fid unnamed.
Both mistakes produce output that looks entirely plausible, and neither shows
up in a single-process test.
On a trace of three concurrent clients the single-slot version produced
twenty-three
.CW "<fid N>"
placeholders and forty-six wrong lines; keyed by tag, none.
.NH
What a Styx trace cannot see
.PP
The interposition is on the name space, so what is captured is what the program
reaches
.I through
the name space.
A program that attaches a kernel device itself does not.
.CW bind
of
.CW "#i"
goes straight to the device, past anything mounted on the way, and none of its
traffic appears.
.PP
This is not a corner case: it is what a graphics program normally does.
And it fails silently, because the result is an empty trace.
.PP
.CW drawbind
exists to demonstrate it, and the shape of that program is the reusable part.
It is one binary with one flag, doing the same work either way \(em allocate a
display and an image through
.CW draw (2)
\(em differing only in whether it binds
.CW "#i"
onto
.CW /dev
itself or inherits a
.CW /dev
its parent bound.
Both runs allocate the image and say so.
The traces do not agree that they did: one shows the opens and the writes, the
other shows nothing at all.
.PP
.B "An empty trace is not evidence on its own" ,
because a program that did nothing produces one too.
The case worth showing is the one where the work demonstrably happened and the
trace is still empty.
An earlier version of this comparison used two
.I different
programs in two configurations and presented it as a single-variable result;
it was not one, and the reproducer had been deleted as scratch.
A file that is the evidence for a documented claim is not scratch.
.NH
Recording below every bind
.PP
To drive the whole system, the thing to reproduce is the input, and it must be
caught below every bind.
.PP
.CW mousetrack
and
.CW gkbdputc
are that seam.
Every platform's window driver already calls them, and no Limbo program can get
underneath.
Two environment variables use them:
.DS I
.CW
INFERNO_INPUT_RECORD=file  emu ...
INFERNO_INPUT_REPLAY=file  emu ...
.R
.DE
.PP
The work is deliberately port-only.
Not one platform file changes, because the hooks are functions the platforms
already call, so the Nt, Plan 9, 9front and X11 drivers get this without being
edited \(em which matters, because none of them can be built or tested here.
.PP
It was verified on a real
.CW wm
session: thirty events recorded while typing at the host, then thirty events
replayed, and the replayed session's Shell window shows the identical
.CW "; echo hellothere"
with nothing touched.
On a single-program test the gaps came back within a millisecond or two, and
pointer states came back with the device's own times preserved.
.NH 2
The control is not a disabled injector
.PP
Turning the injector off and observing nothing shows only that events arrive.
The claim is that they arrive
.I "in order at the right times" ,
and the control for that is a trace with the event order
.I reversed
against the same timeline.
It replays as 111, 108, 108, 101, 104 where the faithful one replays as 104,
101, 108, 108, 111.
That distinguishes order, which is what was actually being asserted.
.NH 2
Three failures that all looked like "no input arrived"
.PP
None of these was found by reading the code.
.IP \(bu
A kproc starts with a fresh file descriptor group and no name space, so the
process draining the ring could not see the descriptor opened for it.
The file was created, the header written, and every event vanished.
.IP \(bu
Times must be relative to the start of the session, not to the first event.
Anchoring on the first event injects it the instant
.CW emu
boots, long before the session's programs are running; the whole recording is
delivered into a queue and read back in one burst.
The order survives that and the timing does not \(em a failure that looks like
success, and it is what the first replay did.
.IP \(bu
A recording made with no window on screen is empty, because the driver has no
key window and never calls
.CW gkbdputc .
The first recordings here were sixteen bytes: a header and nothing else.
.PP
Two things also had to
.I not
be changed.
The recorded time of a pointer event is passed through rather than restamped on
injection, because consumers compare the differences of that time \(em
.CW appl/acme/text.b
treats two clicks less than 500ms apart as a double click \(em so restamping
turns a recorded double click into two single clicks whenever injection drifts,
and does it intermittently.
And the commented-out
.CW mousetrack
in
.CW pointerwrite
stays commented out:
.CW setpointer
already warps the host cursor, which makes the host generate the event, so
injecting as well would deliver it twice.
.NH
What is reproduced, and what is not
.PP
An input recording reproduces the input, not the execution.
Dis scheduling is not recorded, so a program racing two of its own processes
can still diverge on identical input.
.PP
Whether forcing a recorded schedule would be worth building is a question about
how much two runs of the same session actually differ, which is measurable
rather than arguable.
So a schedule recorder was built and the measurement taken, and forcing was
not built.
.PP
Four sites are recorded, not one.
.CW vmachine 's
loop only says which process
.I began
a fresh quantum;
.CW acquire
puts its process back at the
.I head
of the run queue and returns into the middle of the
.CW xec
call it left, so a process that makes a system call and comes back never passes
through the loop.
Recording only the loop would miss every interleaving caused by host calls,
which is most of them.
.DS I
.CW
session              runs   events, iyield dropped   order identical
sequential shell       14   352 every time            yes, 14 of 14
wm, input replayed      3   2776, 2776, 2792          no, at event 83
refstress, 16 procs     3   50592 to 67440            no, at event 145
.R
.DE
.PP
Filtering
.CW iyield
is what makes any of this visible.
A yield is a
.CW vmachine
kproc handing the slot to a process
.I "already waiting for it" :
host-thread bookkeeping that changes nothing about which Dis program runs when.
Left in, it is the only thing that varies in the sequential case, and it swamps
the comparison.
.PP
So a sequential session is reproducible with nothing forced.
Not
.I guaranteed
\(em one divergent pair turned up in about twenty runs \(em so "reliably
reproducible" rather than "deterministic".
Every session with a window in it diverged, and quickly.
.PP
Forcing is therefore the only route for a session with a window in it, and even
there the amount of work is not fixed between runs, so a forced order will
sometimes be impossible to follow: the process the recording says to run next
is blocked, and the process that would wake it is the one being held back.
That is the reason forcing is not built, rather than an oversight.
.NH 2
How a session ends is part of the measurement
.PP
The first version of the
.CW wm
row stopped both runs with a timer from outside and reported that they had done
an identical amount of work.
They had merely been cut off at similar points.
.CW quitall
lets a recorded session end itself \(em
.CW emu
leaves when its last Dis process does, and
.CW wm
has no quit of its own \(em and once the runs were allowed to finish, two of
three matched and the third did not.
.PP
.B "Stopping a comparison from outside measures the timer."
.NH 2
Does the recorder move what it measures?
.PP
Every number above was taken with recording on, and recording takes a lock and
a wakeup on the scheduler's hot path.
If that serialised things, a schedule would look more reproducible than the
virtual machine really is.
.PP
Schedules cannot be compared with the recorder off, so the check is indirect.
.CW refstress
reports how many processes are inside a region containing a host call, which is
order-sensitive and needs no recording.
Twenty runs each way gave the same minimum, maximum and median, with means of
13.3 and 11.7 against a distribution that is mostly sixteen with a tail at
three and four, and the property
.CW refstress
asserts held in all forty.
The recorder does not remove the concurrency it exists to observe.
That is not proof that it perturbs nothing.
.NH
A recording as a script
.PP
An exact recording is unreadable, and something unreadable cannot be edited or
reasoned about.
.CW session (2)
decodes one into
.I actions
and prints them as shell:
.DS I
.CW
# 7 actions, 18.405s
session type 'echo hello'
session wait 1.997
session key Return
session wait 1.978
session type 'quitall'
session key Return
.R
.DE
.PP
Releases are dropped.
Runs of printable keys become one action.
A press and release of a button in one place is a click; two within 500ms are a
double click; one with movement between is a drag.
Quiet longer than a quarter of a second becomes an explicit wait.
.PP
That the script is shell is the design rather than a convenience.
Stopping a replay needs no protocol, because a script that has stopped is a
shell that has not been given its next line, and nothing else is suspended
while that is true.
.CW "session pause"
is exactly that.
It was checked rather than asserted: a script typed
.CW one ,
paused, something else typed
.CW MID
into the live system, and the system received
.CW oneMID .
.NH 2
Two replay paths, which are not the same mechanism
.PP
.CW INFERNO_INPUT_REPLAY
feeds the recorded events back below every bind at the times they originally
arrived.
It is faithful and it cannot be interrupted, because the real keyboard and
mouse are ignored for the duration.
.PP
.CW session
feeds actions through
.CW /dev/keyboard
and
.CW /dev/pointerin .
It is approximate \(em everything is re-timed, and a window resize cannot be
performed at all, because the host owns the window size \(em and it can be
stopped anywhere, edited, and run in pieces.
.PP
Use the first to reproduce a session and the second to demonstrate one or to
take it over.
.NH 2
Closing the loop the other way
.PP
Writing to
.CW /dev/keyboard
and
.CW /dev/pointerin
reaches the non-recording half of the driver, deliberately: a program inside a
session that writes keys runs again on a replay and writes them again, so
recording them as well would deliver them twice.
.PP
That leaves a recording unable to be made from a script, which would block
editing a session and keeping it.
The answer is not a flag to record injections; it is
.CW "session compile" ,
which turns a script back into a recording without a replay and so has nothing
to double and nothing to drift.
.PP
Decoding and compiling are exact inverses.
A hand-written script compiles and decodes to the identical script; a real
recording decodes, compiles and decodes again to identical actions; a third
generation matches the second.
Only the dead time before the first action differs, which a recording has and a
script does not.
.PP
Demanding that fixed point found three defects that reading the code had not.
A double click decoded as a click
.I and
a double click, because the first of the pair was reported before the second
made it a double \(em harmless to read, and the script grew by one action every
generation.
Waits decoded some milliseconds long and grew each generation, because
compiling measured time from wherever it had run on to rather than from the
point the decoder measures the next gap from.
And a pointer movement that is the
.I first
pointer event of a recording was swallowed entirely, because the position it
would be compared against is seeded from that very event, so nothing looks like
movement.
A recording made by hand has hundreds of movements and a later one always
triggers; only a compiled recording has exactly one.
.NH
Working a widget
.PP
Delivering a click and working a widget are different claims, and for a while
only the first had been checked.
.CW inputtest
shows that a click written to
.CW /dev/pointerin
comes back off
.CW /dev/pointer
with the right coordinates and times.
The pointer queue,
.CW wm ,
Tk's dispatch and the widget's own hit testing are all untested by that.
.PP
.CW clicktest
closes it: a button on the screen, its real position written where a script can
read it, and what reaches it written back.
Nothing depends on a screenshot.
.PP
A scripted click does work a real Tk button, twenty-five presses out of
twenty-five.
That is worth stating plainly, because the opposite holds for the neighbouring
case: synthetic clicks posted at the host with
.CW CGEvent
do not work Tk buttons on this platform and fail silently.
.CW /dev/pointerin
goes in underneath the host, so it is not that path.
.PP
A scripted drag drives a menu, and aimed at each of three items in turn it
selects that item and no other.
Three targets and three different answers is the part that matters: one alone
would show only that a menu can be made to do something, whereas the answer
following where the pointer went is what shows the movement is tracked.
.NH 2
Two defects only a widget could find
.PP
.B "Stamps are not enough."
.CW play
stamped a press and a release thirty milliseconds apart and then wrote them
back to back, so they arrived microseconds apart and the widget saw a button
that was never held.
About one click in five was lost.
Without the spacing, thirteen presses in fifteen; with it, twenty-five in
twenty-five.
At the device the events are all present and correctly stamped either way, so
no amount of checking
.CW /dev/pointer
would have found this.
.PP
.B "A widget that moves between clicks looks exactly like clicks being dropped."
Twelve presses in fifteen were arriving, and only ever the repeats \(em a
single click landed four times out of four.
It was not the pointer path.
The test program's own label changed width when it recorded a press,
.CW pack
re-centred what was beside it, and the button walked out from under the next
click.
Script coordinates are absolute and nothing revisits them.
.NH
What the exercise taught
.PP
The mechanisms are in the manual.
What is harder to write down, and cost more, is how to tell whether any of it
works.
.IP \(bu
.B "An absence is not evidence."
An empty trace, a silent replay and a window that looks right are all produced
just as readily by a program that did nothing.
Show the work happening and the observation still failing.
.IP \(bu
.B "Pick a control that distinguishes the actual claim."
Not the injector disabled, which shows only delivery, but the order reversed
against the same timeline, which shows order.
Not one menu item, but three.
.IP \(bu
.B "Measure at the layer the claim is about."
At the device a press and a release are present and correctly stamped whether
or not they are far enough apart to be a click.
Only a widget can say whether a widget was worked.
.IP \(bu
.B "How the measurement ends is part of the measurement."
Stopping two runs with a timer from outside compares where the timer landed.
.IP \(bu
.B "Beware the instrument."
Recording takes a lock on the scheduler's hot path; the reproducibility it
reports could have been its own.
That has to be checked separately and by other means.
.IP \(bu
.B "Repeats, not single samples."
One pair of runs said the sequential schedule diverged; fourteen runs and
thirteen consecutive pairs said it does not.
The single pair was the one-in-twenty case.
.IP \(bu
.B "Build the input when the input is a file."
The click half of the decoder could not be exercised by making recordings,
because synthetic host clicks do not arrive here and injected ones are
deliberately not recorded.
Its real input is a documented format, so it was built.
That found four defects in an afternoon.
.NH
See also
.PP
.CW iostats (4),
.CW styxreplay (1),
.CW styxlog (1),
.CW drawbind (1)
for the name-space layer;
.CW emu (1)
for the environment variables;
.CW inputtest (1),
.CW schedcmp (1),
.CW quitall (1)
for the instruments;
.CW session (2),
.CW sh-session (1),
.CW pointer (3)
for the script layer; and
.CW sessiontest (1),
.CW clicktest (1),
.CW refstress (1)
for the checks.
