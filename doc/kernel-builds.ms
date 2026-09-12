.TL
Kernel Build Layouts
.AU
Inferno RIO
20 August 2026
.PP
This document describes the separation between the host tools, the kernel
flavor, and the target architecture in this tree.  Directory names are
relative to the root of the Inferno source tree.
.PP
The target output directory has the form
.CW flavor/objtype .
For example:
.IP "\f(CWInferno/amd64/\fP" 18
native Inferno headers, libraries and binaries
.IP "\f(CW9front/amd64/\fP" 18
native 9front headers, libraries and binaries
.IP "\f(CWOsprey/amd64/\fP" 18
Osprey headers, libraries and binaries
.IP "\f(CWnix/amd64/\fP" 18
NIX headers, libraries and binaries
.IP "\f(CWMacOSX/arm64/\fP" 18
host-side tools built on this Mac
.LP
.PP
.CW MacOSX/arm64/bin
contains the host programs such as
.CW mk ,
.CW 6c ,
.CW 6a ,
and
.CW 6l .
The
.CW Inferno ,
.CW 9front ,
and
.CW Osprey
directories are target outputs, not host compiler directories.  A target is
selected by the
.CW SYSTARG
and
.CW OBJTYPE
settings in its
.CW mkfile ;
.CW ROOT
continues to name the source tree.
.NH 1
Building a native kernel
.PP
Put the host tools first in
.CW PATH
and enter the mkfile for the desired architecture and flavor.  For example,
the amd64 9front kernel is built from a Mac host with:
.IP
.CW 'PATH="$PWD/MacOSX/arm64/bin:$PATH"'
.br
.CW 'cd os/9front/pc64'
.br
.CW 'mk install'
.PP
This selects
.CW SYSTARG=9front
and
.CW OBJTYPE=amd64
and installs the result below
.CW 9front/amd64/ .
Other native ports use the same procedure with the corresponding mkfile
under
.CW os/ .
.NH 1
Kernels are self-contained
.PP
Each flavor owns one directory under
.CW os :
.CW os/inferno ,
.CW os/9front ,
.CW os/osprey
and
.CW os/nix .
That directory holds everything the kernel is built from:
.IP
portable code in the flavor directory itself
.br
architecture adapters in
.CW pc64
.br
drivers in
.CW pc
.br
boot programs in
.CW boot
.br
the kernel library in
.CW kernlib
.br
kernel headers in
.CW include
and
.CW amd64/include
.PP
No file, header, mkfile or build rule under one flavor names another
flavor's source directory or target tree.  Osprey builds Osprey, Inferno
builds Inferno, 9front builds 9front.  A flavor that needs a file another
flavor has takes a copy of it; the copies are then free to diverge, which
is the point.  Osprey's scheduler, for one, is expected to change how
device interrupts wake driver tasks.
.PP
What is shared is the host toolchain and the flavor-independent sources:
the compilers and loaders under
.CW utils ,
.CW libmach ,
the top-level
.CW include ,
and libraries such as
.CW libsec ,
.CW libmp ,
.CW libfis
and
.CW libkern
that are built from a single source tree for every target.
.PP
The check is mechanical.  From the root of the tree,
.IP
.CW "grep -rn '9front' os/osprey"
.PP
finds no build reference; only comments naming the system a file was
derived from.
.PP
Each flavor is laid out the way Plan 9 and Inferno lay out a kernel:
the portable code in
.CW port ,
one directory for each machine beside it, and
.CW ip ,
.CW boot
and the rest as siblings.
.IP
.nf
os/9front/	port pc pc64 ip boot lib
os/inferno/	port pc pc64 riscv virt sifiveu spike ip boot init
os/osprey/	port pc pc64 ip boot adapter policy lib cmd kernlib libaml
os/nix/		port 386 k8 ip boot mk root lib
.fi
.PP
.CW os
holds those three directories and nothing else.  The portable code used
to lie loose at the top of each flavor with
.CW os/port
beside them as a fourth copy of Inferno's; it is
.CW os/inferno/port
now, and every machine directory reads it as
.CW ../port
as both systems write it.  Headers that belong to a target rather than
to a source tree are in the target:
.CW Osprey/amd64/include
and
.CW Osprey/include ,
beside
.CW Inferno/amd64/include
and
.CW 9front/amd64/include .
.PP
One deviation remains.  The Inferno amd64 kernel does not build, and did
not before the move either:
.CW os/inferno/pc64/l.s
assembles and the objects the mkfile names first compile, but the
configuration bakes a Dis file system into the kernel that is not built
in this tree.  What was checked is that the two kernels that do build,
9front's and Osprey's, build to the same text size as before.  Osprey's
boot file system and the user library its
.CW initcode
links against are prebuilt binaries copied into
.CW Osprey/amd64 ,
not built from source in this tree.
.NH 1
Building the NIX kernel
.PP
.CW os/nix
is rminnich's NIX, jmk's 9k with application cores, vendored the same
way; its README says where it came from and what was changed.  It is
built like the others:
.IP
.CW 'PATH="$PWD/MacOSX/arm64/bin:$PATH"'
.br
.CW 'cd os/nix/k8'
.br
.CW 'mk install'
.PP
which links
.CW nix/amd64/lib/libnix.a ,
the part of the nix user libc the kernel needs, with the tree's
libkern, libsec and libmp, and puts
.CW 9k8cpufs
and
.CW 9k8cpufs.elf
in
.CW nix/amd64 .
The ELF is the multiboot kernel a
.CW "qemu -kernel"
boots; it is linked with
.CW -H5 ,
.CW -8
and
.CW -P0x110000 ,
the physical address of the text.  Two things are inputs rather than
built: the first user process,
.CW os/nix/k8/init.out ,
and the embedded root,
.CW os/nix/k8/k8cpufs.root.s ,
because both are user programs linked against the nix libc, which this
tree does not build.  The k8cpu and k8root configurations need a boot
program of the same kind and are not built either.
.NH 1
Building the Osprey policy library
.PP
Osprey's portable policy code is built as a library of its own so that the
scheduling and queue contracts can be exercised without the rest of the
kernel:
.IP
.CW 'PATH="$PWD/MacOSX/arm64/bin:$PATH"'
.br
.CW 'cd os/osprey/lib'
.br
.CW 'mk install'
.PP
The resulting archive is:
.IP
.CW Osprey/amd64/lib/libosprey.a
.PP
It is compiled with the Osprey target settings, the same ones the kernel
uses, because the loader compares type signatures and the flavors disagree
about the width of
.CW usize .
The kernel links this archive and reaches it through the
.CW #O
device; see
.I osprey (3).
.CW os/osprey/kernlib
builds the kernel's own library subset,
.CW Osprey/amd64/lib/libospreykern.a ,
in the same way.
.NH 1
Hosted and native builds
.PP
Hosted Inferno uses the host target selected by the top-level
.CW mkconfig ,
for example
.CW SYSTARG=MacOSX
and
.CW OBJTYPE=arm64 .
Native kernel mkfiles override those settings locally, allowing a Mac host
to build an amd64 Inferno, 9front or Osprey target without replacing the
host tools.  Keep every part of a kernel in that flavor's directory, and
its objects and libraries in that flavor's target directory.
.NH 1
The compilers, and what came from 9front
.PP
.CW utils
holds the Inferno fork of the Plan 9 compilers, which is a fork of the
same source 9front forked.  9front has kept working on theirs; this
records what has been taken across and what has not, so that the next
pass starts from the list rather than from a diff.
.PP
Taken:
.IP \(bu 2
.CW _Noreturn ,
as a garbage word with its own type bit
.RB ( TNORET ,
.CW GNORET ,
.CW BNORET )
rather than a mark on the symbol, so that it is carried by prototypes
and by function pointers; and the
.CW "case OFUNC"
in
.CW pgen.c
that clears
.CW canreach
at a call to one.
.IP \(bu 2
.CW codgen
refusing to hand the backend a function that already has errors, and
.CW usedset
taking a nil node.
.IP \(bu 2
.CW scon.c :
a constant fold that crossed a cast from an unsigned type of a
different width, which is wrong when the modulus changes.
.IP \(bu 2
.CW dpchk.c :
two walks off the end of
.CW fmtbuf
in the
.CW "#pragma varargck"
parser, and
.CW %z
as a known verb sized to the pointer.  9front does not need the cast
that turned up in
.CW archmp.c
because the file is theirs for a 32 bit kernel, where a long is the
width of a pointer;
.CW arith
types a pointer difference identically in both compilers.
.IP \(bu 2
.CW funct.c :
a hundred byte buffer for a name built from a struct tag.
.IP \(bu 2
.CW acid.c :
the acid verb for a pointer, which was the thirty-two bit one.
.IP \(bu 2
.CW pickle.c :
its debugging flag, which was
.CW -P ,
the peephole flag.
.IP \(bu 2
.CW tc
and
.CW 0c :
.CW outlstring
written for a two byte rune while its caller counts bytes of
.CW TRune .
.PP
Not taken, and why:
.IP \(bu 2
The host layer.  9front replaced
.CW Posix.c ,
.CW Nt.c ,
.CW Plan9.c
and
.CW 9front.c
with one
.CW compat.c
against their own libc.  These utils are built on a Mac.
.IP \(bu 2
.CW TRune .
Inferno cross-compiles, so the target's rune width is not the host's;
9front hardcodes
.CW Rune
because it does not.
.IP \(bu 2
The hunk allocator.  9front dropped
.CW gethunk
and
.CW alloc
for plain malloc.  That touches every file and buys nothing here.
.IP \(bu 2
.CW lex.c
wholesale.  Most of its difference is 9front's
.CW smprint
and their argument handling; this tree's
.CW lex.c
carries the
.CW __APPLE__
cpp handling that lets it build on a Mac at all.  The dynamic
.CW defs ,
.CW av
and
.CW ofile
buffers in it are a real fix and are worth a pass of their own.
.IP \(bu 2
.CW com.c :
a mixed assign-op kept the type of the arithmetic rather than of what
was being assigned to;
.CW zpconst ,
so that a comparison against a null pointer constant keeps the pointer
type through the casts to
.CW void* ;
a call to a function with no declaration at all said "args not checked"
as though there were one, and now says it is not declared, which found
.CW addconf
called from three
.CW pc64/main.c
with the declaration only in
.CW pc/fns.h ;
a constant divisor of zero, said rather than folded; a cast to void
with no side effect dropped, and
.CW ccom
made safe against being called on the same node twice.  And the
useless-comparison checker: reversing a comparison used
.CW comrel
where it wanted
.CW invrel ,
its bounds were computed with an
.CW add
that could itself overflow, and it skipped every cast on the left --
including the narrowing ones that are the whole reason the comparison
might be useless -- and then took the type from the symbol rather than
from the expression.
.IP \(bu 2
.CW fndecls ,
.CW thisfnnode ,
.CW OROL ,
.CW sextern ,
.CW paramconv 's
dropped argument,
.CW macexpand 's
new signature, and
.CW "case a ... b" .
Features rather than fixes.
.IP \(bu 2
The backends.  6c, 8c, 5c, kc, vc and qc are between two hundred and a
thousand changed lines each of per-architecture code generation and
peephole work, with no shared test surface here.
.CW 0c
and
.CW jc
have no 9front counterpart at all.
.PP
.CW utils/cc/lexbody
is shared by every assembler and carries this tree's own fix for
.CW //
comments, which must survive anything taken from 9front:
.CW "goto l1"
rather than
.CW "goto l0" ,
so that the newline an assembler needs as a statement separator is not
swallowed with the comment.
