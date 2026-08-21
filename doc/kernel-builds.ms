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
.IP
.CW Inferno/amd64/	 native Inferno headers, libraries, and binaries
.br
.CW 9front/amd64/	 native 9front headers, libraries, and binaries
.br
.CW Osprey/amd64/	 Osprey headers, libraries, and binaries
.br
.CW MacOSX/arm64/	 host-side tools built on this Mac
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
.CW 'cd os/pc64/9front'
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
The kernel mkfile selects portable flavor code from
.CW os/inferno ,
.CW os/9front ,
or a future
.CW os/osprey
adapter, while hardware support remains in shared architecture directories
such as
.CW os/pc
and
.CW os/pc64 .
.NH 1
Building the Osprey policy library
.PP
Osprey's portable policy code is currently a library rather than a bootable
kernel.  Its mkfile uses the Inferno C compiler configuration for ABI
compatibility, while placing its artifacts in the separate Osprey target
tree:
.IP
.CW 'PATH="$PWD/../../../MacOSX/arm64/bin:$PATH"'
.br
.CW 'cd os/osprey/lib'
.br
.CW 'mk install'
.PP
The resulting archive is:
.IP
.CW Osprey/amd64/lib/libosprey.a
.PP
When another Osprey object type is added, its mkfile can select that
.CW OBJTYPE
and the matching host compiler in the same manner.
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
to build an amd64 Inferno or 9front target without replacing the host tools.
Keep flavor-specific objects and libraries in their own target directory;
put shared drivers in the common architecture directories and portable
kernel code in the corresponding flavor directory.
