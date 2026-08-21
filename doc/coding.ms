.TL
Plan 9 and Inferno Coding Style
.AU
Inferno RIO
20 August 2026
.PP
This note records the naming and implementation conventions used by Plan 9,
Inferno, and 9front code in this tree.  The conventions are intentionally
compact: source is read often in the kernel, and the surrounding directory
already supplies much of the name space.
.NH 1
Names
.PP
Use the shortest clear contraction that is established by the system.  The
usual kernel names are
.CW Proc ,
.CW Mach ,
.CW Chan ,
.CW Pgrp ,
.CW Fgrp ,
.CW Qid ,
.CW Dir ,
and
.CW Dev .
Prefer
.CW proc ,
.CW qopen ,
.CW qclose ,
.CW devtab ,
and
.CW waserror
to expanded forms such as
.CW Process ,
.CW queueopen ,
.CW queueclose ,
.CW devicetable ,
and
.CW errorhandler .
.PP
The directory is part of the name space.  Code in
.CW os/osprey
uses local names such as
.CW Task ,
.CW Queue ,
.CW Core ,
and
.CW runtimeinit ;
it does not repeat
.CW Osprey
in every identifier.  Add a flavor prefix only when an interface crosses a
name-space boundary and would otherwise collide.
.PP
Use lower-case names for functions and variables, upper-case initial letters
for exported types and constants, and mixed-case only where existing Inferno
interfaces require it.  Keep abbreviations consistent: do not alternate
.CW qid ,
.CW QID ,
and
.CW queueid .
.NH 1
Control flow and errors
.PP
Use the Plan 9 error mechanism for recoverable kernel failures:
.CW waserror ,
.CW error ,
and
.CW poperror .
An error path is a non-local transfer; do not add a normal
.CW return
after
.CW error
as if it were an ordinary status call.  Pair every successful
.CW waserror
with
.CW poperror
and release resources in the recovery branch.
.PP
Use return values for ordinary predicates and resource operations whose
caller can continue.  Use
.CW nil
for absent pointers, test arguments at the boundary, and keep invariant
checks close to the data structure they protect.
.NH 1
Data and concurrency
.PP
Keep structures explicit and storage-oriented.  Kernel layers should accept
caller-provided storage when possible, avoid hidden allocation, and leave
machine-specific barriers and locks to the architecture adapter.
.PP
Use intrusive lists and queues when ownership is unambiguous.  Document the
producer and consumer for lock-free queues, and state which layer supplies
the memory barrier.  Do not introduce a general locking abstraction merely
to hide an architecture-specific ordering rule.
.NH 1
Portability
.PP
Share behavior through configuration, device tables, and runtime capability
checks.  Do not use
.CW #ifdef
to select a flavor or architecture when a mkfile, device table, or adapter
can express the difference.  An unavoidable conditional must explain its
necessity beside the conditional.
.PP
Keep portable policy in the flavor directory and hardware, trap, and MMU
code in the architecture directory.  A portable file must not include
.CW Mach ,
device registers, or trap-frame definitions merely to obtain a convenience
helper.
.NH 1
Formatting
.PP
Use tabs for C indentation, one declaration per line, and the existing brace
placement.  Keep functions small enough that the state transitions are
visible.  Comments should explain an invariant, ownership rule, or hardware
constraint; do not restate the statement immediately below them.
