.TL
A network database machines can join and leave
.AU
.PP
The tree's network database is a set of text files.
.CW /lib/ndb/local
names the machines, and a machine is in it because somebody wrote it
there.  That is fine for a laboratory with a fixed list of hosts and
useless for a set of machines that come up, get an address, do some
work and go away, which is the only kind of machine a cloud provider
rents.  This document is about the piece that was missing, what already
existed, what was built, and what was run on a booted kernel to show it
works.
.NH 1
What was already there
.PP
Half the problem was solved in 2003 and nobody connected it to the
other half.
.PP
.CW registry(4)
is a file server whose whole purpose is registration of services that
come and go.  A machine opens its
.CW new
file, writes a name and a set of attribute/value pairs, and an entry
appears in the registry's directory.  The entry lives exactly as long
as that file descriptor: close it, kill the process holding it, or lose
the connection to a remote registry, and the entry vanishes.  There is
an
.CW index
file listing every entry, a
.CW find
file that filters them, and an
.CW event
file whose read blocks until something changes and coalesces changes
while it waits.  Joining and leaving, in other words, were already
built, tested and documented.
.PP
.CW appl/svc/registry.sh
already exports a registry over
.CW "tcp!*!registry" ,
so a registry shared by many machines was already built too.
.PP
What no part of the tree did was let anything that reads the network
database see any of it.
.CW cs(8)
opens
.CW /lib/ndb/local
and
.CW /net/ndb
through
.CW attrdb(2)
and knows nothing about registries;
.CW dial(2)
and everything above it go through
.CW cs .
A machine could register itself and still be unreachable by name.
.NH 1
The bridge
.PP
.CW ndb/regndb
is a file server that renders a registry as an
.CW attrdb(6)
database.  It serves 9P on its standard input, the way
.CW registry
does, and presents two files.
.CW ndb
is the rendered database.
.CW ctl
reports the registry being watched, the key attribute, the generation,
how many services were rendered, how many were skipped, how many
attribute pairs were dropped and the last error; writing
.CW refresh
to it re-renders at once.
.PP
It blocks on the registry's
.CW event
file, so it costs nothing while the network is quiet, and re-renders on
every change.  If the registry becomes unreachable it renders an empty
database \- stale host entries are worse than none \- and tries to
attach again every two seconds.
.PP
Three details decide whether a thing like this works at all.
.PP
.B "The version has to move."
.CW Dbf.changed
in
.CW appl/lib/attrdb.b
decides that a database has changed by comparing
.CW dev ,
.CW dtype ,
.CW Qid.path ,
.CW Qid.vers
and
.CW mtime
against a fresh
.CW stat .
A synthetic file whose qid version never moves is a database
.CW attrdb
will read once and cache forever.
.CW regndb
increments a generation on every rendering and returns it as
.CW Qid.vers .
.PP
.B "The static files have to come with it."
.CW Db.open
reads the first entry of the file it is given, and if that entry is
.CW database=
with
.CW file=
lines, it opens those as well and keeps its own file at the head of the
list.  So the rendered file begins with
.IP
.DS L
.CW
database=
	file=/lib/ndb/local
.R
.DE
.LP
and a caller that opens
.CW /mnt/regndb/ndb
gets the dynamic entries first and the static ones behind them.  No
change to
.CW cs
was needed:
.CW "ndb/cs -f /mnt/regndb/ndb" .
.PP
.B "Not every registration is a host."
A registry holds a mixture: Grid services registered as
.CW service=tcp!master!6679 ,
machines registered as
.CW sys= .
Rendering the first kind as host entries would corrupt lookups.
.CW regndb
takes the ndb key from an attribute \-
.CW sys
by default,
.CW "-a attr"
to override \- and skips every entry that does not carry it, counting
the skips in
.CW ctl .
.PP
Quoting is the one place the two formats do not line up exactly.  The
registry's
.CW index
is
.CW sh (1)-quoted;
.CW attrdb
understands the same single quotes with a doubled quote for a literal
one, so values with spaces and equals signs round-trip.  A newline
cannot: nothing in
.CW attrdb
looks at quoting until after it has split an entry into lines.  A pair
whose name or value contains one is dropped and counted, rather than
written out to be mis-parsed.  An empty value is written
.CW ''
and read back as an attribute with no value; that is recorded in the
manual page and not papered over.
.PP
A registration carrying an attribute called
.CW regsvc
is dropped and counted the same way, since that is the name
.CW regndb
gives the registry's own service name and two of them on one line
would make a lookup depend on which came first.
.NH 1
Joining
.PP
.CW ndb/register
is the other half.  It writes a service name and attribute/value pairs
to a registry's
.CW new
file and then holds that file descriptor, so the registration lasts
exactly as long as the process.
.CW -p
marks the entry
.CW persist
and returns at once;
.CW -r
removes one.
.PP
.DS L
.CW
ndb/register 'tcp!10.42.0.7!0' sys joiner1 ip 10.42.0.7 dom joiner1.test
.R
.DE
.LP
becomes, in the rendered database,
.DS L
.CW
sys=joiner1
	regsvc=tcp!10.42.0.7!0 dom=joiner1.test ip=10.42.0.7
.R
.DE
.NH 1
What was run
.PP
.CW os/inferno/init/ndbinit.b
is the test, and
.CW os/inferno/virtarm64/virtarm64ndb
is the board that runs it: the
.CW virtarm64
kernel exactly, with that init and the extra Dis modules its root file
list needs.  It runs on QEMU
.CW "-M virt -cpu cortex-a72" ,
a real 64-bit AArch64 kernel with no host underneath it.
.PP
The first phase starts
.CW ndb/registry
and
.CW ndb/regndb
on pipes, mounts both, checks that the name is absent, has
.CW ndb/register
join in a process of its own, looks the name up through
.CW attrdb
the way
.CW cs
does and through
.CW ndb/query
the way an operator does, kills the registering process, and looks it up
again.
.PP
.DS L
.CW
NDB-REGISTRY-MOUNTED /mnt/registry
NDB-REGNDB-MOUNTED /mnt/regndb
NDB-EMPTY-OK joiner1 absent before anyone joins
NDB-JOIN pid 11 registering joiner1
NDB-JOIN-OK joiner1 ip=10.42.0.7 after 100 ms
--- ndb/query -f /mnt/regndb/ndb sys joiner1 ip
10.42.0.7
--- end ndb/query
NDB-CHANGED-OK quiet database reports no change
NDB-KILL pid 11
NDB-CHANGED-OK Db.changed() true 100 ms after the leave
NDB-LEAVE-OK joiner1 gone after 0 ms
--- ndb/query -f /mnt/regndb/ndb sys joiner1 ip
--- end ndb/query
.R
.DE
.PP
The two
.CW NDB-CHANGED-OK
lines are the qid version test: a database nobody has touched reports
no change, and one whose registry lost an entry reports a change within
a poll.  Without the version bump the second line would never appear
and every consumer would be reading a snapshot from boot.
.PP
The second phase is the awkward registrations: a value with a space, a
value with a quote, and an attribute called
.CW regsvc .
.PP
.DS L
.CW
sys=quirk1
	regsvc=tcp!10.42.0.9!0 note='it''s' desc='a b c' ip=10.42.0.9

NDB-QUOTE-OK desc='a b c' note='it''s'
NDB-REGSVC-OK regsvc=tcp!10.42.0.9!0, the registration's own was dropped
NDB-QUIRK-OK quirk1 gone after 100 ms
.R
.DE
.LP
with
.CW "dropped 1"
in
.CW ctl :
the two quoted values round-trip through both quoting schemes, and the
registration's own
.CW regsvc
was dropped rather than written out beside the real one, where a lookup
would have taken whichever came first.
.PP
The third phase is the one that matters for a network.  It brings up
loopback, announces on
.CW tcp!127.0.0.1!6699 ,
exports
.CW /mnt/registry
over that connection, mounts it back at
.CW /mnt/netreg ,
and has a third machine join through the mount.  Then it writes
.CW hangup
to the connection's control file: the connection dies with nothing
clunked and nothing unmounted, the way a machine that has gone away
dies.
.PP
.DS L
.CW
NDB-NET-MOUNTED /mnt/netreg over tcp!127.0.0.1!6699
NDB-NET-JOIN-OK joiner2 ip=10.42.0.8 after 100 ms
NDB-NET-HANGUP tcp!127.0.0.1!6699
NDB-NET-LEAVE-OK joiner2 gone 100 ms after the connection dropped
.R
.DE
.PP
Exportfs tears its fids down when the connection dies, which clunks the
registry fid, which strikes the entry off, which posts the event, which
re-renders the database.  Nothing in that chain was written for this;
all of it was already there except the last link.
.NH 1
What this is not
.PP
All three phases ran inside one kernel.  The network phase used a real TCP
connection over the loopback medium and a real
.CW exportfs ,
so the mechanism is the same one two machines would use, but two
kernels talking to each other over a wire have not been run.
.PP
The registry was exported with no authentication.  A shared registry on
a real network wants
.CW listen -v
and the authentication
.CW registries(2)
already speaks; that was not part of this and is not claimed.
.PP
.CW cs
was not run against
.CW /mnt/regndb/ndb
on a booted kernel.  The lookups above went through
.CW attrdb
directly and through
.CW ndb/query ,
which is the same library and the same file
.CW cs
would open, and the
.CW database=
chaining was written so that
.CW "ndb/cs -f /mnt/regndb/ndb"
needs no change to
.CW cs
\- but that command has not been run here.  Note that
.CW cs
opens its databases once, when it starts:
.CW regndb
has to be mounted before it, and nothing reports the mistake if it is
not.
.PP
Re-rendering reads the registry's
.CW index
in the same process that answers 9P, so a slow or distant registry
stalls readers of the served files.  That is recorded in the manual
page.
