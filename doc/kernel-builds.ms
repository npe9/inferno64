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
and
.CW os/osprey .
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
os/inferno/	port pc pc64 ip boot init and a directory per machine
os/osprey/	port pc pc64 ip boot adapter policy lib cmd kernlib libaml
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
