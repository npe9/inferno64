.TL
A 9front tree that builds with this tree's compilers
.AU
Inferno RIO
.PP
This tree had a 9front kernel and no 9front user space.
.CW os/9front
builds
.CW 9pc64
with the compilers in
.CW utils ,
and
.CW 9front/amd64/lib
held libraries that nothing here had built: there was no
.CW sys/src ,
so the note in
.I doc/osprey-gap.ms
that \(lqrio is an import, not a build\(rq was exactly right.
.PP
.CW 9front-src
is a 9front source tree that this tree builds.  It is upstream's,
imported by
.CW scripts/import-9front.sh
at a pinned commit, and built by
.CW scripts/mk9front.sh
with
.CW 6c ,
.CW 6a
and
.CW 6l
into
.CW 9front/amd64/lib
and
.CW 9front/amd64/bin ,
beside the kernel.
.NH 1
Why the import rewrites anything
.PP
9front's build wants paths that exist only on a 9front machine.  Every
library and command mkfile begins
.CW "</$objtype/mkfile" ,
the rule files it then includes are
.CW </sys/src/cmd/mkone
and its relatives, libraries and binaries install to
.CW /$objtype/lib
and
.CW /$objtype/bin ,
and thirty-five C sources and headers name an include by absolute
path \(em libmach
reads every architecture's
.CW ureg.h
and every loader's object format that way.  None of that resolves
here, and the only way to make it resolve would be to create
directories at the root of the build machine.
.PP
So the import rewrites them, mechanically, in one place.
.CW scripts/import-9front.sh
is that place: it fetches the pinned commit, copies the parts that are
source, and applies the substitutions, so moving to a newer upstream
is one command and the same rewrite.  What it rewrites is listed at
the top of the script and nowhere else, and it is worth reading before
changing anything: the rule is that mkfiles are rewritten freely, C
sources only for absolute includes, and \(em for the two generators
that have to run on the build machine \(em one main() signature and
one hardcoded input path, both noted in the script.
.NH 1
What the toolchain was missing
.PP
Five things, all real, none of them anticipated.
.NH 2
mk could not run rc
.PP
9front's mkfiles are rc scripts.  A recipe reading
.EX
	for(i in $PORTDIRS $objtype ucd)@{ cd $i; mk $MKFLAGS install }
.EE
is a syntax error to sh, and
.CW utils/mk
ran everything under
.CW /bin/sh
with no way to say otherwise.  It does now:
.CW mkshell()
in
.CW utils/mk/Posix.c
reads
.CW MKSH
from the mkfile and execs it, searching the path when the name has no
slash.
.PP
The name is
.CW MKSH ,
not Plan 9 mk's
.CW MKSHELL ,
and that was learned the hard way.  Honouring
.CW MKSHELL
looked more faithful until it broke the 9front kernel:
.CW os/9front/pc64/mkfile
has said
.CW MKSHELL=rc
since it was written, that line had always been inert, and the mkfile
had therefore always been built under sh.  Making it mean something
changed how an existing, working build ran.
.CW MKSH
is the name
.CW utils/mk/Nt.c
has read for as long as it has existed, nothing in the tree sets it,
and so nothing in the tree changes.
.NH 2
mk parses one shell's syntax, compiled in
.PP
Running rc is not enough.  The dialect mk parses mkfiles in decides
how a backquote is closed, which characters end an assignment, and how
a substituted word is quoted, and it is chosen at compile time by
which of
.CW sh.c
and
.CW rc.c
is linked.  9front's mkfiles are full of
.CW "`{ls | sed ...}" ,
a command substitution to rc and a syntax error to sh.  So
.CW utils/mkrc
builds the same sources against
.CW rc.c
as
.CW mkrc ,
and the Inferno tree keeps the sh-flavoured
.CW mk
it has always used.  Nothing about the existing build changes.
.NH 2
An empty variable arrived as a list of one empty string
.PP
.CW AFLAGS=
in a mkfile is an empty list.  On Plan 9 rc reads it back as one:
.CW /env/AFLAGS
is a zero length file.  Through a Unix environment it came back as a
list holding one empty string, so a recipe reading
.CW "$AS $AFLAGS $stem.s"
handed the assembler an empty file name before the real one, and every
assembly file in 9front's libc failed.  mk now exports nothing rather
than an empty value, and only when the shell is rc: sh cannot tell an
unset variable from an empty one, so the Inferno build is unaffected,
and the distinction is carried by
.CW emptyisnolist
in the two dialect files rather than guessed at.
.NH 2
The assembler had no JMPF
.PP
9front's libc enters
.CW _callmain
from
.CW _main
with
.CW JMPF ,
a near jump that always takes the five byte rel32 form and that the
loader follows when working out what calls what.  This tree's
.CW 6a
and
.CW 6l
had never heard of it.  They have it now \(em
.CW utils/6c/6.out.h ,
.CW utils/6c/enam.c ,
.CW utils/6a/lex.c ,
and
.CW Zjmpf
through
.CW utils/6l 's
.CW l.h ,
.CW optab.c ,
.CW span.c
and
.CW pass.c ,
where it encodes like a call and takes part in the call graph like
one.
.PP
The opcode is appended after
.CW AMODE ,
at the very end of the enumeration, and that placement is the point:
an object file records the opcode as a number, so inserting one
anywhere earlier would silently change the meaning of every object
already built in this tree.
.NH 2
Host tools
.PP
9front builds its generators for the machine it runs on, because that
is the same machine.  Here it is not:
.CW 6c
makes amd64 9front objects and
.CW libc/ucd 's
.CW mkrunetype ,
which turns the Unicode data files into libc's tables, has to run on
the build host.  The mkfiles ask for the host's compiler by reading
.CW /$cputype/mkfile ,
and a mkfile that needs a whole tool built for the host \(em awk's
.CW maketab
\(em runs
.CW mk
again with
.CW objtype=$cputype .
The build sets
.CW cputype=host
and the import writes
.CW 9front-src/host/mkfile ,
a copy of
.CW 9front-glue/host/mkfile ,
where it is maintained.  It names two wrappers around the host
.CW cc
that build against this tree's own host
.CW lib9
and
.CW libbio
\(em the libraries every tool under
.CW utils
is already built against, so no other Plan 9 user space is needed to
make one.  Two small things go with them:
.CW u.h
and
.CW libc.h
shims, because this tree's host header is
.CW lib9.h ,
and
.CW _assert ,
which 9front's libc has and lib9 does not.
.NH 1
What builds
.PP
All thirty-nine libraries under
.CW sys/src ,
from source, including the three that were open questions:
.CW libc
with its Unicode tables,
.CW libsec
and
.CW libauthsrv
with the elliptic-curve arithmetic
.CW mpc
generates from their
.CW .mp
sources, and
.CW libmach ,
which needed binary literals in the compiler.
.PP
Sixteen of the seventeen APE libraries, which is all of them that
have sources here; see below.
.PP
Of the command directories under
.CW sys/src/cmd ,
126 of 134 build and install, and 559 programs end up in
.CW 9front/amd64/bin .
That directory was emptied before the run, so the number is what this
toolchain built, not what has accumulated in it.  The count is from
the run before the last two rewrite rules landed \(em the
.CW -I/sys/include/ape
and
.CW lib/keyboard
ones below \(em and it has not been taken again since.  The only
directory those rules touch is
.CW aux ,
which still fails for the reason named below, so 126 and 8 are
unchanged by them.
.CW scripts/sweep9front.sh
produces it, and it builds each directory on its own rather than
stopping at the first failure the way
.CW mk install
does, which is the only way to see what is actually missing.  It
builds them in name order and independently, so a directory that
needs a library another one builds can fail on order alone:
.CW bzfs
wants
.CW bzip2 's,
and comes first.
.NH 1
Bugs in this tree's tools, found by building 9front with them
.PP
None of these are 9front's.  They are in
.CW utils
and in the host
.CW lib9 ,
they are all old, and each one had been sitting under some program
this tree has never compiled.
.IP \(bu
.CW utils/cc
had no binary constants.
.CW 0b111110
is in
.CW libmach 's
power64 disassembler and 9front's own
.CW 6c
takes it.  Added to the number scanner and to
.CW mpatov ,
which turns the scanned text into a value.
.IP \(bu
.CW utils/libregexp 's
.CW optimize
relocates a compiled program after
.CW realloc
moves it, and held the displacement in an
.CW int .
On a 64-bit host
.CW realloc
can move a block further than an
.CW int
reaches, the truncated displacement is added to every pointer in the
program, and the next match reads a wild address.
.CW mk
hit it on
.CW libc/spim 's
regular-expression rules and died of a bus error, which stopped
.CW mk clean
in
.CW libc
and so stopped the library sweep before it began.  The displacement
is an
.CW intptr
now.
.IP \(bu
Every linker in
.CW utils
names a floating-point constant by printing the two halves of its
.CW Ieee
with
.CW "$%lux.%lux"
into
.CW char
.CW literal[32] ,
and the comment beside it says the result is 18 characters at most.
It is, where
.CW long
is 32 bits.  Where it is 64 the halves are sign-extended, a negative
one prints sixteen digits instead of eight, and the name overruns the
buffer into
.CW nerrors ,
which is the next thing in bss.  So
.CW 6l
linked
.CW clock ,
finished, saw a nonzero error count that no
.CW diag
had ever incremented, deleted the output and exited 1 with nothing
printed at all.  Found with a watchpoint on
.CW nerrors .
The two halves are masked to 32 bits now, in all eleven linkers.
.IP \(bu
.CW utils/mk
exported a variable with an empty value to a recipe, which
.I rc
reads as a one-element list containing the empty string rather than as
nothing.  Fixed earlier in the port;
.CW emptyisnolist
in
.CW rc.c
is the flag.
.IP \(bu
Not this tree's, but the same shape: plan9port's
.I rc
runs a script named on the command line by sourcing it, and
.CW .
looks the name up on
.CW $path ,
which has no current directory during a build.  9front's
.CW 9l/mkcname
is run as
.CW "rc mkcname" .
.CW 9front-glue/bin/rc
gives the name a directory and passes it on.
.IP \(bu
.CW utils/6c 's
.CW xcom
dereferences the left operand of an
.CW OCAST
without checking whether there is one.  A cast with no operand \(em
.CW (void)f()
among others \(em reaches it with that pointer nil and the compiler
dies of a bad address, silently, with no diagnostic and no line
number.  9front's own
.CW 6c
has the guard and this one did not; the source that found it was
.CW libdraw/subfont.c ,
compiled for APE.
.IP \(bu
.CW lib9 's
.CW runetype.c
declares
.CW _runebsearch
at the top and defines it nowhere.  Every Unicode predicate in the
library \(em
.CW isalpharune ,
.CW isspacerune ,
.CW tolowerrune
and the rest \(em calls it, so every one of them has been an
undefined symbol for as long as the file has existed.  Nothing in the
tree had ever called one from a host tool.  The search is written out
now, and
.CW lib9/runetest.c
checks it against answers that do not depend on the tables: ASCII,
Greek, Cyrillic, a Latin-1 accented letter, an em space and an
Arabic-Indic digit, through both the pairs the predicates index and
the triples the case conversions do.
.CW "mk runetest"
in
.CW lib9
runs it.
.NH 1
A bug in 9front, found the same way
.PP
.CW libc/ucd/mkrunetype ,
the generator that makes libc's Unicode tables, walks a rune's
decomposition chain with
.EX
	for(x = i, n = 0; r1 = mydecomp[x]>>16; x = r1)
.EE
and
.CW mydecomp
is an array of signed
.CW int .
A singleton decomposition whose target has bit 15 set \(em U+F900, the
first CJK compatibility ideograph, goes to U+8C48 \(em is stored as
0x8C480000, which is negative, and the arithmetic shift sign-extends
it to 0xFFFF8C48.  That is not in the range the loop recognises as a
marker, so it becomes the next index and the walk reads
.CW mydecomp[-1] .
On a 9front machine whatever precedes
.CW mydecomp
in bss is zero and the walk stops there by luck.  Here the array
before it is
.CW mytolower ,
every element of which
.CW main
has just set to \-1, so the walk follows \-1 to \-1 for ever: that is
the eleven minutes at 100% of a core this document used to report as
an unexplained hang.  The import shifts through
.CW uint ,
which is the reading the loop wants.
.PP
The four tables the generator then writes are in
.CW libc.a
and
.CW yacc ,
which is what wanted
.CW isalpharune ,
links.  They have not been checked against Unicode's own conformance
data:
.CW libc/test
has the programs that would do it and they are amd64 Plan 9 binaries,
which this machine cannot run.  What is verified is that the generator
runs, terminates and writes four tables, and that what links against
them works.
.NH 1
APE
.PP
APE is 9front's ANSI/POSIX environment: a second set of headers and a
second libc, which a dozen commands are written against \(em
.CW compress ,
the troff preprocessors,
.CW spin .
Their mkfiles set
.CW CC=pcc
and
.CW LD=pcc ,
and 9front's
.CW pcc
is a program that runs on 9front.
.CW 9front-glue/bin/pcc
is that driver written for this machine: it does what
.CW sys/src/cmd/pcc.c
does, running the source through
.CW cpp
and then the compiler, and linking against
.CW ape/libap.a .
Sixteen of the seventeen APE libraries build, and with them
.CW compress ,
.CW eqn ,
.CW grap ,
.CW pic ,
.CW spin
and
.CW lp .
.CW libz
does not build, and cannot: upstream ships its mkfile and a proto
file and no zlib sources, so it does not build on a 9front machine
either.
.PP
Four things had to be true before any of that worked, and each was
its own small discovery.
.IP \(bu
The
.CW cpp
is real, not the compiler's own.  APE's headers open with
.CW "#if !defined(_RESEARCH_SOURCE) && !defined(_PLAN9_SOURCE)"
and neither 9front's compiler nor this tree's understands
.CW #if
at all.  That is why 9front's pcc pipes through cpp rather than
handing the source to the compiler, and it is not a nicety.
.CW 9front-glue/host/mkhost.sh
builds
.CW sys/src/cmd/cpp
for this machine.
.IP \(bu
That cpp crashed on every source it was given.  It calls
.CW ctime(time(0))
for
.CW __DATE__ ,
and Plan 9's
.CW ctime
takes the seconds themselves where the host's takes a pointer to
them, so it died inside
.CW localtime .
.CW 9front-glue/host/include/time.h
and
.CW unistd.h
put the Plan 9 spellings of
.CW ctime
and
.CW dup
back over the host's declarations, after those have been read; the
supporting functions are in
.CW hostsupp.c .
.IP \(bu
.CW pcc
piped cpp into the compiler, and a shell pipeline reports the last
stage's status.  A cpp that died left the compiler reading nothing,
which it accepted: an empty object, no message, and a link failing
much later about a symbol whose source had compiled fine.  cpp writes
to a file now and its status is checked.
.IP \(bu
The parser
.CW iyacc
writes calls
.CW sprint ,
which Plan 9's libc has and APE's
.CW libap
has not, so any APE program with a grammar in it did not link.
9front's own yacc writes a parser against 9front's libc \(em the one
being built here \(em so that is the yacc the build runs, built for
this machine like cpp and mpc.  It needs its skeleton, which is why
the import now brings
.CW sys/lib/yaccpar
across, and two functions this tree's libraries have not got:
.CW fd2path ,
which is
.CW F_GETPATH
here, and
.CW Blethal ,
which is nothing here and is documented as nothing in
.CW hostsupp.c .
.NH 1
What does not build yet
.PP
Eight of the 134 command directories, and they are eight separate
problems rather than one.
.IP \(bu
.CW aux ,
because of
.CW kbdfs :
its
.CW mklatin
turns
.CW lib/keyboard
into a header, and built for this machine it traps rather than
running.  Everything else under
.CW aux
builds, including
.CW antiword ,
which needed one more rewrite rule (its mkfile writes
.CW -I/sys/include/ape
outright) found after the sweep.
.IP \(bu
.CW jpg ,
whose table generator is a host tool that wants
.CW cmap2rgb
from libdraw.  There is no libdraw for the host and no reason to
build one except this.
.IP \(bu
.CW bzfs ,
which wants
.CW bzip2 's
library and is built before it.  That is the sweep's ordering, not a
failure to compile: it builds when
.CW bzip2
has been.
.IP \(bu
.CW cwfs ,
.CW ext4srv ,
.CW nusb :
compile errors not yet read.
.IP \(bu
.CW test ,
which has no
.CW install
target at all, and the top of
.CW cmd
itself, which fails because it loops into
.CW aux .
.PP
None of this is doubt about the chain.  Every one of these has a
program beside it that built.
.NH 1
Building it
.EX
	scripts/mk9front.sh 9front-src/sys/src libs
	scripts/mk9front.sh 9front-src/sys/src/cmd install
	scripts/sweep9front.sh
.EE
The driver sets what 9front's mkfiles expect:
.CW ROOT ,
an rc to run recipes under,
.CW ccroot
so
.CW 6l
finds
.CW -lc
in the target tree,
.CW cputype
for the tools that must run here,
.CW CPP
for the preprocessor
.CW 6c
runs when a mkfile asks for one, the target
.CW bin
subdirectories a 9front machine already has, the host tools the build
runs rather than installs, and a path with
.CW 9front-glue/bin
first \(em where
.CW mk
is
.CW mkrc ,
.CW ar
is
.CW iar ,
.CW yacc
is
.CW iyacc ,
.CW pcc
is the APE driver and
.CW rc
is the shim above \(em then this tree's compilers, then a Plan 9 user
space for
.CW sed
and
.CW tr ,
because 9front's mkfiles use Plan 9 regular expressions and a BSD or
GNU
.CW sed
does not understand them.
.PP
A working
.I plan9port
is therefore needed for
.CW rc
and
.CW sed .
It is not needed to compile anything: host tools are built against
this tree's own libraries, which is deliberate \(em the plan9port on
the machine this was written on cannot link a hello-world, and the
build does not depend on it being able to.
.NH 1
Nothing under 9front-src is written by hand
.PP
Everything in
.CW 9front-src
is what
.CW scripts/import-9front.sh
put there.  What is ours lives outside it, in
.CW 9front-glue :
the
.CW mk ,
.CW ar ,
.CW yacc ,
.CW rc
and
.CW pcc
shims, and the host compiler wrappers.  The import begins by removing
the whole imported tree, so anything kept inside it would be lost on
the next one; and an edit made there by hand would be undone silently,
which is worse.  A change that the imported tree needs goes in the
script, as a rule.
.PP
This was not true when the tree was first committed.  The build glue
lived under
.CW 9front-src ,
where re-running the import would have deleted it, and twenty-one C
files carried the absolute path of the machine they were imported on,
because the rewrite of their
.CW #include
lines wrote it in.  Those includes now lose their leading slash and
are found through
.CW -I$ROOT/9front-src ,
so the tree names no machine but through
.CW ROOT ,
which comes from the environment.  Re-running the import over the
committed tree changes nothing, which is the property that makes
moving to a newer upstream one command.
.PP
A build does write there \(em
.CW mkone
links the program as
.CW $O.name
in the directory it was built in and leaves it \(em and five of those
were committed once before anyone noticed.  The
.CW .gitignore
the import writes now covers them, and because
.CW $O
is one character the patterns also catch upstream source
.CW ( libmach/6.c ,
.CW cmd/6c/6.out.h ),
which negations put back.  An ignore rule that reaches too far drops
upstream files silently, which is how twenty of awk's test files went
missing once, so the import ends by asking git which of the files it
just wrote are ignored and failing if the answer is not none.  Right
after an import every file under
.CW 9front-src
came from upstream and none of them may be ignored; that is the whole
invariant.
.NH 1
What is left out of the import
.IP \(bu
.CW sys/src/9 ,
the kernel:
.CW os/9front
already holds one, and a flavour here owns its kernel directory alone.
.IP \(bu
.CW sys/src/cmd/gs ,
a bundled ghostscript, 31 MB, which nothing needs to build a system.
.IP \(bu
.CW lib
and
.CW sys/lib
\(em fonts, ndb, troff tables: runtime data, not source.
.CW lib/ucd
is the exception and does come across, because libc generates its
Unicode tables from it, which makes it a build input.
.NH 1
Toward a full system
.PP
.CW $ROOT/9front
is the root of the system being built: what a deployed 9front would
have at
.CW / .
The import rewrites every install path in the tree to sit under it \(em
.CW /$objtype/bin
and
.CW /$objtype/lib ,
and also
.CW /sys/lib ,
.CW /rc/bin ,
.CW /acme
and the font and keyboard directories, which is where the mkfiles put
runtime data.  So the tree fills itself in as more of it builds.
.PP
What is left, in order: the eight directories above; then the runtime
data the import deliberately leaves behind \(em fonts, ndb, the troff
tables \(em which a deployed root needs and no compiler produces;
then an image.  The pieces for the last part are here \(em
.CW .qemu/9front-root.qcow2
is a full 9front installation the tests boot, and
.CW scripts/mkosprey-efi-iso.sh
knows how to make a bootable image \(em with the
.CW 9pc64
that
.CW os/9front
already builds.
