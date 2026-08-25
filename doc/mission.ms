.TL
Capturing What an Institution Used to Carry
.AU
Noah Evans
noah.evans@gmail.com
.AB
.PP
Plan 9 solved a social problem before it solved a technical one: how a small,
mutually trusting working group turns a room of workstations into one
timesharing system.
Every design choice that follows from that \(em one namespace per process,
devices as files, a network transparent enough that a terminal and a CPU
server are the same kind of thing \(em is downstream of already having the
part that is hardest to build: a group of people who trust each other, sit
near each other, and can explain a design decision to one another in a
hallway.
.PP
That institution is usually the first thing missing when a system like this
is picked up again.
The code survives; the hallway does not.
This paper states the problem this fork of Inferno is actually trying to
solve, which is not "keep an old operating system running" but "carry the
part an institution used to carry" \(em the folklore, the reasons a thing is
shaped the way it is, the intuition a design decision came from \(em without
the institution.
And it argues that accessibility, treated as a first-class property of the
system rather than an add-on, is not a separate feature competing for effort
with that goal.
It is close to being the same goal, approached from a different angle.
.PP
This is a placeholder: a statement of the problem and the argument, written
down before it is fully proven out, so that the shape of the claim exists
before the evidence for it is complete.
.AE
.NH
The problem Plan 9 actually solved
.PP
It is easy to describe Plan 9 by its mechanisms \(em everything is a file,
namespaces are private and mutable per process, 9P is the same protocol
whether the file is local or across the world \(em and to miss that these
are answers to a narrower question than "how should an operating system
work."
The question was closer to: given a research group who already trust each
other, already work near each other, and already share norms about what a
well-designed interface looks like, how do we let them share a fleet of
machines as if it were one machine, without any one of those machines
becoming a bottleneck or a single point of failure.
.PP
The trust was load-bearing.
A namespace you can freely rearrange is only safe in a group where nobody
is trying to attack you through it.
A protocol with no encryption by default is only reasonable when the wire is
inside a lab, or trusted the way phone lines used to be trusted.
None of this is a criticism \(em it is the correct engineering choice for
the problem actually in front of them \(em but it means the system encodes
an assumption about who is using it and how they already relate to each
other, and that assumption does not travel with the source code.
.PP
Neither does the rest of what made the system usable.
A design decision that looks strange out of context \(em why does
.CW newwindow
behave this way, why is
.I limbo
typed the way it is, why did this device end up shaped like this and not the
obvious alternative \(em had a reason, and the reason usually lived in a
conversation, not a comment.
When the group disperses, the code is still correct and the reasons are
gone.
Anyone who picks the system up afterward is reverse-engineering intent from
artifact, which is slower, less reliable, and available to fewer people than
the original conversation ever was.
.NH
The problem now
.PP
This fork is not trying to reassemble that research group.
It cannot, and pretending otherwise would be its own kind of failure \(em a
system that only pretends the institution still exists is worse than one
that admits it doesn't.
The actual research question is different and, as far as this project can
tell, less worked-on: how does a system capture and transmit the folklore,
the teaching, and the intuition an institution used to carry, when there is
no institution to carry it \(em when the people who might learn the system
are not in the room, not on the same schedule, and not necessarily even
looking at a screen at the same time as anyone else who knows the answer.
.PP
Concretely, that has meant building the system so that it can explain
itself, rather than relying on someone standing nearby to explain it.
A narrated tutorial that drives the actual shell while it talks (\c
.CW tour.sh ,
.CW namespace.sh )
is an attempt to put "someone explaining this over your shoulder" into the
system itself, replayable, editable, and stoppable rather than one-time and
person-shaped.
A session recording that reproduces exactly what a person did, and a script
form that reads like the shell commands it decodes into, are an attempt to
make "here is what I did and why it didn't work" something the system can
carry losslessly, instead of a screenshot and a half-remembered description.
A pronunciation lexicon that gets
.CW chmod
and
.CW libtk
and
.CW fsck
right is a small thing on its own, but it is evidence for the larger claim:
the folklore of how this system's own vocabulary is actually said out loud
was never written down anywhere, and had to be reconstructed rather than
looked up, the same way any other unwritten institutional knowledge would
have to be.
.PP
The two Unix-for-Poets-shaped demos built alongside this paper are a smaller
version of the same argument in miniature.
The point of Church's original talk was never really about text processing;
it was about a way of thinking \(em small tools, composed, over real data \(em
that was folklore at Bell Labs before it was a slide deck.
Reproducing it here, once faithfully with this tree's own small tools and
once by showing what this shell's own loadable modules already cover instead
of a language it was never handed, is an attempt to show a design philosophy
being taught by demonstration rather than by assertion.
.NH
Accessibility as the same problem, not a second one
.PP
It would be easy to treat accessibility \(em a screen reader, a system that
can be operated without seeing it \(em as a separate, worthy, but competing
use of effort: teaching-and-folklore over here, accessibility over there,
each drawing from the same finite attention.
That framing is wrong, and the reason it's wrong is the actual argument of
this paper.
.PP
A system that can be explained to someone who cannot see it has to make its
own structure explicit.
It cannot rely on a screenshot, a spatial layout, a color that means
something only if you can see the color.
It has to say, out loud and in words, what changed, what has focus, what
kind of thing this is.
Building that seriously \(em a screen reader that already knows everything
the window manager and the toolkit know, because the announcement is wired
into the same place focus itself changes, rather than a bolted-on layer
guessing at the screen \(em forces the system to expose the assumptions a
sighted user was silently relying on the whole time.
Every one of those exposed assumptions is also exactly the kind of thing a
newcomer needs explained and a hallway conversation used to supply for free.
.PP
Put differently: accessibility is a forcing function for legibility.
A design decision that only makes sense if you can see it drawn a certain
way is a design decision with a hidden dependency, and hidden dependencies
are precisely the folklore this project is trying to make explicit instead
of tacit.
Treating accessibility as first class does not compete with capturing the
system's own teaching and history.
It is a discipline that produces that capture as a side effect of being done
properly, because it does not let a design decision hide behind something
only a sighted, already-initiated person would understand without asking.
.NH
What this paper is not yet
.PP
This is stated as a placeholder because the claim is ahead of the evidence
for it.
What exists so far is a screen reader wired into window-manager and toolkit
focus rather than guessing at pixels; narrated, driveable tutorials that
teach by demonstration; a session-recording mechanism that makes "here is
what happened" a first-class, replayable artifact instead of a story; and a
pronunciation lexicon that had to reconstruct folklore no one had written
down.
Each is real and separately useful.
What is not yet established is the larger claim that these add up to a
system capable of carrying an institution's worth of tacit knowledge on its
own \(em that is a research claim, not yet a research result, and this paper
exists to say so plainly rather than to overclaim what four tools and a
handful of demos have actually shown.
