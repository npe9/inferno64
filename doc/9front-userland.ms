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
and twenty-two C files name a header by absolute path \(em libmach
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
.CW /$cputype/mkfile ;
the import points that at
.CW 9front-src/host/mkfile ,
which names two wrappers around the host
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
.CW libc ,
except for the Unicode tables:
.CW 9sys ,
.CW 9syscall ,
.CW fmt ,
.CW port
and the amd64 assembly, 259 objects.
.PP
Thirty-six of the thirty-nine libraries under
.CW sys/src .
.PP
And a linked binary:
.CW cat
builds and links against that libc and is an amd64 Plan 9
.CW a.out ,
which is the milestone that says the whole chain works \(em compiler,
assembler, archiver, loader, headers, and the mkfiles driving them.
.NH 1
What does not build yet
.IP \(bu
.CW libsec
and
.CW libauthsrv
want
.CW mpc ,
which compiles their
.CW .mp
sources and is itself a 9front program.  It is the same host-tool
problem
.CW mkrunetype
had and it is solved the same way; it has not been done.
.IP \(bu
.CW libmach
uses binary literals \(em
.CW 0b111110
\(em which 9front's
.CW 6c
takes and this tree's does not.  That is a small addition to
.CW utils/cc 's
number scanner and it has not been made.
.IP \(bu
.CW libc/ucd ,
which generates libc's Unicode tables.  Its generator now compiles and
links as a host tool, and then does not terminate: two runs spun at
100% of a core for eleven minutes without writing a table, so
something this tree's
.CW lib9
does differently from 9front's libc keeps a loop in it going.  It is
excluded from the build until that is found, which means
.CW isalpharune
and its relatives are missing from
.CW libc.a .
.CW yacc
is the first program that wants them, and because it is a program the
rest of the build needs, this is what stands between here and a
command sweep worth reporting.
.IP \(bu
The commands.  There are 155 of them in
.CW sys/src/cmd
alone and they are built by
.CW mkmany ,
which stops at the first failure rather than carrying on, so one
broken program hides the rest.  The sweep gets as far as
.CW yacc ,
which cannot link without the Unicode tables above.  No number is
claimed here because none has been measured.
.NH 1
Building it
.EX
	scripts/mk9front.sh 9front-src/sys/src/libc install
	scripts/mk9front.sh 9front-src/sys/src/cmd cat.install
.EE
The driver sets what 9front's mkfiles expect:
.CW ROOT ,
an rc to run recipes under,
.CW ccroot
so
.CW 6l
finds
.CW -lc
in the target tree, and a path with
.CW 9front-src/bin
first \(em where
.CW mk
is
.CW mkrc ,
.CW ar
is
.CW iar
and
.CW yacc
is
.CW iyacc
\(em then this tree's compilers, then a Plan 9 user space for
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
The order is: make the Unicode tables build, then the two libraries
that want
.CW mpc ,
then the commands, then a root to put them in.  The tree already has the pieces for the last part \(em
.CW .qemu/9front-root.qcow2
is a full 9front installation the tests boot, and
.CW scripts/mkosprey-efi-iso.sh
knows how to make an image \(em so the deployable end is a root built
from
.CW 9front/amd64/bin
plus the runtime data the import leaves behind, booted by the
.CW 9pc64
that
.CW os/9front
already builds.  None of that is done, and the honest statement of
where this stands is: the toolchain is proved, libc and
thirty-six of thirty-nine libraries are built, one command compiles
and links into a valid amd64
.CW a.out ,
and what remains is understood work rather than doubt.
