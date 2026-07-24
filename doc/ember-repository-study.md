# Ember Repository Study: How Limbo, Dis, and the Inferno Runtime Actually Work

This document is the Phase 0 deliverable for Ember, a successor language to
Limbo. It records what exists in the `inferno64` tree, with file paths, so
that every Ember design decision can be checked against the real system.

The governing rule: **extend Inferno, do not replace it**. Ember is a new
front end for the existing Limbo/Dis tool chain. Dis, the VM, the scheduler,
module loading, namespaces, Styx/9P, and the garbage collector are assumed
correct and are not modified.

Contents:

1. Repository map
2. The Limbo compiler (`limbo/`)
3. The Dis object format (`.dis`)
4. The Dis runtime (`libinterp/`, `emu/port/`)
5. The module interface system (`module/*.m`, signatures)
6. How existing language features are represented in Dis
7. Applications suitable as a validation suite (`appl/`)
8. Build system
9. Dependency graph and pipelines
10. Where Ember hooks in (recommendation)
11. Reuse decisions: attempted, adopted, rejected
12. Where Dis is not expressive enough (watch list)

---

## 1. Repository map

Directories that matter for a language front end:

    limbo/          the Limbo compiler (C, yacc). ~20 files, one binary.
    include/isa.h   Dis instruction set, addressing modes, header flags
    include/interp.h runtime structs: Module, Modlink, Frame, REG, Prog, Type
    libinterp/      the Dis VM: loader, interpreter, GC, channels, JIT
    emu/port/       hosted emulator portable core: scheduler, exceptions
    emu/MacOSX/     host bindings for this machine (arm64 Mach-O)
    module/         ~182 Limbo interface files (.m): sys.m, draw.m, bufio.m...
    appl/           Limbo applications: cmd/, lib/, wm/, math/, ...
    dis/            compiled .dis binaries, mirroring appl/
    mkfiles/        mk build rules (mkone, mkdis, mksyslib, per-host/target)
    mkconfig        ROOT, SYSHOST=MacOSX, OBJTYPE=arm64, OBJDIR
    doc/limbo/      the Limbo paper, syntax summary, tutorial
    doc/dis.ms      the Dis VM specification
    man/6/dis       .dis file format man page; man/6/sbl debug format
    tests/          ad-hoc language/VM samples (adt.b, alt.b, tuple.b...)
    ember/          NEW: the Ember front end (this project)

Host binaries live in `MacOSX/arm64/bin/` (`limbo`, `emu`, `emu-g`, `mk`,
`iyacc`, ...). The tree also carries a 64-bit port: `WORD`/`IBY2WD` is
pointer-sized (8 bytes) in the VM, while the on-disk `.dis` scalar encoding
is unchanged (see section 3.6).

---

## 2. The Limbo compiler (`limbo/`)

One C program, built from `limbo/mkfile` (`TARG=limbo`), grammar in yacc.
`main()` is in `limbo/limbo.y:1639`; per-file driver `translate()` at
`limbo.y:1857`.

### 2.1 Phase structure

    translate(in, out, sbl)                 limbo/limbo.y:1857
      lexstart / popscopes / typestart / declstart
      yyparse()                             grammar limbo/limbo.y -> tree
      entry = typecheck(...)                limbo/typecheck.c:199
      modcom(entry)                         limbo/com.c:204
        fncom() per function                com.c:365  (scom -> ecom -> Inst)
        optim() if -O                       limbo/optim.c:1754
        layout globals, resolve pcs/descs
        dis* writers (or asm*/sbl*)         limbo/dis.c, asm.c, sbl.c

### 2.2 Lexer

- `limbo/lex.c`: `lex()` at lex.c:881, exposed as `yylex()` (lex.c:1091).
- Keyword table `keywords[]` (lex.c:50); operators `tokwords[]` (lex.c:101).
- Symbols interned in hash tables via `enter()` (lex.c:1204).
- `include "file.m"` is a **lexer-level** include stack: `includef()`
  (lex.c:308) pushes a Biobuf; search path is cwd, `-I` dirs, then
  compile-time `INCPATH` (`$ROOT/module`).
- Source coordinates: absolute lines mapped through a `File` table
  (`fline()`, lex.c:367), printed with the `%L` format.

### 2.3 Parser and AST

- Grammar: `limbo/limbo.y`. Entry nonterminal `prog` (limbo.y:73):
  optional `implement ids;` then `topdecls`. Result stored in global
  `tree` after `rotater()` normalizes `Oseq` lists to right-leaning.
- AST is a single `Node` struct (`limbo/limbo.h:428`): `op, left, right,
  ty, decl, val, rval, src`. Node kinds are the `O*` enum (limbo.h:273):
  `Oadtdecl, Omoddecl, Oimport, Oload, Ocall, Omdot, Ospawn, Osnd, Orcv,
  Oalt, Ocase, Opick, Oexstmt, Oraise, ...`
- Lists are `Oseq` chains; there are no vector children.
- `.m` interface files have **no separate parser**: they are ordinary
  source included into the translation unit.

### 2.4 Symbol table

- `limbo/decls.c`. `Decl` (limbo.h:191) carries storage class (`Dtype,
  Dfn, Dglobal, Darg, Dlocal, Dconst, Dfield, Dtag, Dimport`, limbo.h:173),
  scope index, and an `old` pointer chaining shadowed declarations.
- Scopes are a stack: `pushscope`/`popscope` (decls.c:647, 672);
  `installids()` (decls.c:753) binds ids; `lookup()` (decls.c:785).
  `ScopeBuiltin=0, ScopeNils=1, ScopeGlobal=2` (limbo.h:58).

### 2.5 Type checker

- Driver `typecheck()` (`limbo/typecheck.c:199`): `gdecl` (install
  globals) -> `gbind` (bind types) -> `gcheck` -> per-function `fncheck` ->
  `scheck` (statements) -> `echeck` (expressions, typecheck.c:983).
- Types: `Type` struct (limbo.h:517) with `T*` kinds (limbo.h:443):
  `Tadt, Tadtpick, Tarray, Tbig, Tbyte, Tchan, Treal, Tfn, Tint, Tlist,
  Tmodule, Tref, Tstring, Ttuple, Texception, Tfix, Tpoly` plus internal
  kinds (`Tiface`, `Tinst`, ...).
- Structural equality `tequal` (types.c:2800), assignability `tcompat`
  (types.c:2601), verification/sizing via `usetype` (types.c:1059).
- **Module signatures**: `sign()` (types.c:3540) serializes a type to a
  canonical string (`rtsign`), MD5s it (libsec), and XOR-folds the digest
  to a 32-bit `sig`. This is the value checked at `load` time (section 5).

### 2.6 Code generation

- Statement compile: `scom()` (`limbo/com.c:459`); expressions `ecom()`
  (`limbo/ecom.c:816`); instruction emission `genop/genrawop/genmove`
  (`limbo/gen.c:262-495`) into a linked `Inst` list with symbolic
  addressing (`Rreg` v(fp), `Rmreg` v(mp), `Rdesc`, `Rpc`, `Rmpc`,
  limbo.h:397).
- Calls: `IFRAME`+`ICALL` intra-module, `IMFRAME`+`IMCALL` cross-module
  (ecom.c:1703). `load` -> `ILOAD` (ecom.c:1279). `raise` -> `IRAISE`.
- GC descriptors: `mkdesc/mktdesc/descmap` (types.c:2396, 2505) produce
  pointer bitmaps (`Desc`, limbo.h:231) for every frame, global area, and
  heap type.
- Object writer `limbo/dis.c` (header assembled in com.c:309-335); textual
  assembly `limbo/asm.c` under `-S`; debug symbols `limbo/sbl.c`
  (format string "limbo .sbl 2.1", sbl.c:56).

### 2.7 Optimizer

`limbo/optim.c` (enabled by `-O`, entry `optim()` at optim.c:1754). Not a
peephole pass: it builds basic blocks and use-def chains, removes dead
stores (mostly redundant nil-ing), and shares overlapping local slots.
Ember does not inherit this; its own lowering can start naive (the VM
and JIT tolerate redundant moves) and grow an equivalent pass later,
using optim.c as the reference.

### 2.8 Stub generator

`limbo/stubs.c` (`-a/-A/-t/-T/-d` flags): emits C headers and `Runtab`
tables for builtin modules (Sys, Draw, ...). This is how `libinterp/runt.h`
and `sysmod.h` are generated (libinterp/mkfile:58-92). Ember does not need
to replicate this; it only consumes builtin interfaces.

---

## 3. The Dis object format (`.dis`)

Authoritative sources: `man/6/dis`, `doc/dis.ms`, writer `limbo/dis.c`,
reader `libinterp/load.c:parsemod` (load.c:163-630), Limbo-level parser
`appl/lib/dis.b` (interface `module/dis.m`).

### 3.1 Sections, in order

    header       XMAGIC (819248) or SMAGIC (923426, signed)
                 runflags, stack-extent,
                 code-size, data-size, type-size, link-size,
                 entry-pc, entry-type
    code         instructions: opcode byte, address-mode byte, operands
    types        type descriptors: number, memsize, mapsize, map bytes
    data         initialization items (DEF* opcodes) building the MP area
    module name  UTF-8, NUL terminated
    links        exports: pc, desc, sig (word), name
    imports/LDT  if HASLDT: per-module lists of (sig, name)
    handlers     if HASEXCEPT: pc ranges, frame offset, case tables
    source path  written by limbo (dispath); C loader ignores it

Integers use the compact "operand" encoding (1/2/4 bytes by MSB); the
fixed "word" scalar is 4 bytes big-endian even on the 64-bit port.

### 3.2 Instructions

Opcodes: `I*` enum in `include/isa.h:4-182` (`MAXDIS` = 0xA2 region).
Addressing byte packs middle/source/dest modes (isa.h:191-249): MP-relative,
FP-relative, immediate, single indirect through MP/FP. The runtime `Inst`
(op, add, reg, s, d) is `include/interp.h:179`.

### 3.3 Header flags (isa.h:230-236)

`MUSTCOMPILE (1<<0)`, `DONTCOMPILE (1<<1)`, `SHAREMP (1<<2)`,
`DYNMOD (1<<3)`, `HASLDT0 (1<<4, obsolete/rejected)`, `HASEXCEPT (1<<5)`,
`HASLDT (1<<6)`. (`man/6/dis` documents HASLDT as 1<<4; the code disagrees
— trust `isa.h`.)

### 3.4 Type descriptors

On disk: `desc-number memsize mapsize map...`; in memory `Type`
(interp.h:201): size, pointer bitmap `map[]`, one bit per word-sized slot,
MSB = lowest address. Created by `dtype()` (libinterp/heap.c:249). The GC,
frame initialization (`initmem`), and destruction (`freeptrs`) are all
driven by these maps — a front end must get them exactly right, but gets
them for free by reusing `limbo/types.c` descmap machinery.

### 3.5 Data section

`DEF*` items (isa.h:206-215): DEFB/DEFW/DEFS/DEFF/DEFL scalar pours,
DEFA/DIND/DAPOP for nested arrays. Parsed into the module's pristine
globals `origmp` (load.c:341-453).

### 3.6 64-bit notes

`IBY2WD = sizeof(intptr)` = 8 on this port (isa.h:226). Data layouts,
frame offsets, and pointer maps are computed in units of the *native*
word; the on-disk scalar encodings stay 32-bit. Consequence: `.dis` files
must be produced by a compiler configured with the same `IBY2WD` as the
target VM (the in-tree limbo binary is). Ember inherits this by reusing
limbo's sizing code (`limbo/types.c:sizetype`), never hard-coding sizes.

### 3.7 Tools

- Assembler: `appl/cmd/asm/` (asm.b, asm.y) — a full Dis assembler.
- Disassembler: `appl/cmd/disdump.b` over `appl/lib/dis.b`.
- Debug format `.sbl`: writer `limbo/sbl.c`, reader `appl/lib/debug.b`
  (`loadsyms`), consumed by `appl/wm/deb.b`. Ember must eventually emit
  `.sbl` too — same writer if we reuse the back end.

---

## 4. The Dis runtime

### 4.1 Interpreter

`libinterp/xec.c`: `xec()` (xec.c:1771) runs a quantum (`PQUANTA` = 2048,
interp.h:30) of decode (`dec[]`, libinterp/dec.c) + dispatch (`optab[]`,
libinterp/optab.h). VM registers: `REG` (interp.h:213) — `PC, MP, FP, SP,
TS, EX, M`. Frames start with `lr, fp, mr, t` (`Frame`, interp.h:81;
`REGLINK..REGRET`, isa.h:219).

### 4.2 Scheduler

`emu/port/dis.c`: `vmachine()` (dis.c:1042) round-robins the `isched`
ready queue of `Prog`s (interp.h:243). Dis processes are multiplexed over
a small number of host pthreads (`kproc-pthreads.c`); a blocked Prog parks
in a channel queue, not a host thread. Nothing here concerns a front end.

### 4.3 Channels

`Channel` (interp.h:119): send/recv Progq, optional ring buffer.
`INEWCW/INEWCP/...` create; `ISEND/IRECV` rendezvous or buffer
(xec.c:1010-1086); `IALT/INBALT` via `libinterp/alt.c:xecalt`. The
compiler shapes an alt table in MP/FP; layout comes from `limbo/ecom.c:altcom`.

### 4.4 Processes

`ISPAWN` (xec.c:691): `newprog()` (emu/port/dis.c:121) clones scheduling
state, **shares the parent's `Modlink`** (module instance and its MP).
`IMSPAWN` spawns into another module. Process groups, kill, and exception
propagation are per-Prog fields.

### 4.5 GC

Hybrid: reference counts (`destroy`, libinterp/heap.c:223) plus an
incremental tri-color mark-sweep for cycles (`libinterp/gc.c:rungc`,
gc.c:335). Everything is driven by `Type.map` pointer bitmaps
(`markheap`, gc.c:108). A front end's only obligation: correct
descriptors and correct use of the `IMOVP`-family instructions — Ember
emits both itself; correctness is what matters (every ref slot marked,
nothing mismarked), not resemblance to limbo's descriptors.

### 4.6 Module loading and linking

`ILOAD` (xec.c:772) -> `readmod` (libinterp/readmod.c) -> `parsemod`
(libinterp/load.c) -> `linkmod` (libinterp/link.c:94). Builtins
(`$Sys`, `$Draw`, ...) are registered by `builtinmod()`
(libinterp/runt.c:394) from limbo-generated `Runtab` tables. Loaded
modules are cached by path (`lookmod`). `$self` shares the current
instance. JIT (`comp-*.c`) is applied at load time when `cflag` or
`MUSTCOMPILE`; it consumes the same Dis, so front ends ignore it.

### 4.7 Exceptions

`IRAISE` (xec.c:1378) + per-module handler table (`Module.htab`,
interp.h:346, parsed at load.c:546). Handler search and frame unwinding:
`emu/port/exception.c:handler` (exception.c:89). String patterns support
`*` suffix matching. Ember's `Result`/`?` deliberately do *not* use this
machinery (they are ordinary values and branches); real exceptions remain
available for interop and can be surfaced later.

---

## 5. The module interface system

### 5.1 Interfaces

A `.m` file declares a module type: constants, adts, function signatures,
and a conventional `PATH: con "..."` (either `$Builtin` or a `/dis/...`
file). Examples: `module/sys.m` (builtin, `"$Sys"`), `module/bufio.m`
(`"/dis/lib/bufio.dis"`). Interfaces are consumed by textual `include`
plus a module-typed variable; implementations declare `implement M;`.

### 5.2 Verification, exactly

There is no structural check at run time — only signature equality:

1. Compiling a caller, limbo computes a 32-bit MD5-folded signature per
   used import (`limbo/types.c:sign`, types.c:3540) and writes them in the
   LDT import section.
2. Compiling an implementation, limbo writes the same signatures on its
   export links (`limbo/dis.c:dismod`).
3. At `load`, `linkmod`/`linkm` (`libinterp/link.c:35-68`) resolves each
   import by name and requires `l->sig == sig`, else
   `"link typecheck m->f() sig/sig"` and the load yields nil.

So **any** compiler that computes the identical signature for the
identical Limbo type gets full, checked interop with every existing
module. This is the single most important interop fact in the tree:
Ember must reproduce `sign()` bit-for-bit — which it does trivially by
reusing `limbo/types.c`.

### 5.3 Cross-module calls

`m->f(x)` compiles to `IMFRAME` (frame type from the callee's link) +
`IMCALL` (xec.c:811). If the callee is a builtin (`ml->prog == nil`), the
VM calls the C `Runtab` function instead. Ember emits the same ops.

---

## 6. How existing features are represented in Dis

| Feature | Compile-time | Runtime representation |
|---|---|---|
| ADT (value) | `Tadt`, fields sized sequentially (`sizeids`) | flat bytes in frame/MP/heap; pointer map marks ref slots |
| ADT (ref) | `Tref` of `Tadt` | heap cell + `Heap` header; `INEW` with descriptor |
| pick ADT | `Tadtpick`; per-tag sizes | **ref-only**; leading tag word (`IBY2WD`), then common fields, then arm fields; discriminated by `ICASE` on the tag; tags are small consecutive ints |
| array | `Tarray` | `Array` heap struct (interp.h:104): len, elem type, root (slices alias!), data. `INEWA`, `IINDX`, `ISLICEA` |
| list | `Tlist` | cons cells (`List`, interp.h:112); `ICONSW/IHEADW/ITAIL` |
| string | `Tstring` | `String` heap struct, ascii or runes; `IADDC`, `IINDC`, `ISLICEC`, `ILENC` |
| tuple | `Ttuple` | flat bytes like a small value adt; multi-value returns are tuples |
| channel | `Tchan` | `Channel` heap struct; `INEWCW...`, `ISEND/IRECV/IALT` |
| ref fn | `tfnptr` tuple `(Modlink, index)` (types.c:209) | two words; call via `Oind` -> `IMFRAME/IMCALL`; **no environment slot** |
| exceptions | `Texception`; handler tables per fn | `IRAISE` + `Module.htab` unwinding |
| polymorphism | `Tpoly`; constraints `for { T => f: fn... }` | **type erasure + dictionary passing**: hidden `(module,index)` arg pairs appended per constrained method (`decls.c:addfnptrs`, decls.c:1141); NOT monomorphization |
| closures | — | **do not exist**. `ref fn` captures nothing. |

Two consequences for Ember, both solvable purely in the front end:

- **Ember closures** must be lowered. Plan: a closure value of type
  `func(A) R` becomes a ref adt `{ env fields...; fn (Modlink,index) }`
  whose code is a lifted top-level function taking the env adt as an
  implicit first argument. Direct calls devirtualize; escaping closures
  go through the two-word fn ref. No VM change.
- **Ember generics** are monomorphized (per the design brief): each
  instantiation elaborates to a distinct Core IR function/adt before
  lowering, so the emitted Dis contains only concrete types. Limbo's
  erasure convention matters only if Ember ever calls a *polymorphic*
  Limbo API (deferred until a concrete need appears). No VM change.

---

## 7. Validation suite from `appl/`

Graduated set, all compiled by the in-tree limbo today (paths + features):

| Program | ~LOC | Exercises |
|---|---|---|
| `appl/cmd/echo.b` | 36 | minimal module, load Sys, strings, lists |
| `appl/cmd/cat.b` | 48 | byte arrays, fd loops, raise |
| `appl/cmd/seq.b` | 92 | Arg+Bufio module chaining |
| `appl/cmd/sort.b` | 129 | multi-module load, lists/arrays |
| `appl/cmd/cmp.b` | 151 | seek/read, structured raise |
| `appl/cmd/wc.b` | 303 | case, UTF scanning, globals, exit |
| `appl/cmd/lego/timers.b` | 263 | spawn, chan of, concurrency |
| `appl/cmd/sh/file2chan.b` | 461 | pick ADTs, channels, $self |
| `appl/lib/hash.b` | 80 | library module, self methods, sigs |
| `appl/cmd/calc.b` | ~2500 | exceptions, tuples, big recursive descent |

Plus in-tree micro samples `tests/adt.b`, `tests/alt.b`, `tests/tuple.b`.
Milestone plan: Ember interop tests first call these modules unmodified;
later milestones port `echo`, `cat`, then `timers` to Ember and diff
behavior under `emu`.

How to run on this host:

    export PATH=$ROOT/MacOSX/arm64/bin:$PATH
    limbo -I $ROOT/module -gw file.b     # .b -> .dis + .sbl
    emu /path/inside/inferno/file.dis    # JIT on by default on arm64
    emu -c0 ...                          # force interpreter

---

## 8. Build system

- `mkconfig`: `ROOT`, `SYSHOST=MacOSX`, `OBJTYPE=arm64`,
  `OBJDIR=MacOSX/arm64`; includes `mkfiles/mkhost-MacOSX` (shell tools)
  and `mkfiles/mkfile-MacOSX-arm64` (cc flags).
- C programs: per-dir mkfile sets `TARG/OFILES/LIBS`, includes
  `mkfiles/mkone-sh`; `mk install` copies to `$ROOT/$OBJDIR/bin`.
  The limbo compiler itself builds this way (`limbo/mkfile`, yacc via
  `iyacc`, links bio/math/sec/mp/9).
- Dis modules: per-dir mkfile sets `TARG` and `DISBIN`, includes
  `mkfiles/mkdis`; rule is `limbo -I$ROOT/module -gw x.b`, install to
  `dis/...`.
- Emulator: `emu/MacOSX/mkfile` (Cocoa `emu`, console `emu-g`).
- Tests: no formal harness; `emu/MacOSX/smoke-arm64.sh` compiles and runs
  a smoke program both JIT and interpreted. Ember adds its own runner at
  `ember/tests/run.sh` (`mk test`).

The Ember front end follows the same pattern: `ember/mkfile` with
`TARG=ember`, `mkone-sh`, installed next to `limbo`.

---

## 9. Dependency graph and pipelines

Compiler pipeline today (Limbo) and target pipeline (Ember):

    Limbo:   .b/.m --lex/yacc--> Node tree --typecheck--> typed Nodes
             --com/ecom--> Inst list --optim--> dis.c --> .dis (+ .sbl)

    Ember:   .e --ember/lex.c,parse.c--> Ember AST
             --resolve/typecheck (M2)--> typed Ember AST
             --elaborate (M3)--> Core IR (vars, fns, closures, cells,
                                 products, sums, control flow, module
                                 calls, chan ops, spawn)
             --lower--> Inst list --> .dis (+ .sbl)

    Ember compiles to Dis directly. It does not link against or emit
    Limbo; the limbo sources are the *reference implementation* for
    every contract Ember must honor: data layout (types.c:sizetype),
    GC descriptor maps (types.c:descmap/mktdesc), interface signatures
    (types.c:sign), instruction selection and addressing (gen.c,
    optab.c, disoptab), and the object writers (dis.c, sbl.c).

Runtime pipeline (unchanged, both languages):

    .dis --readmod/parsemod--> Module --linkmod (sig check)--> Modlink
         --xec interpreter | comp-* JIT--> execution
         Progs scheduled by emu/port/dis.c; heap via heap.c/gc.c;
         channels via xec.c/alt.c; namespaces & Styx via emu devices

What Ember depends on (and must match exactly):

    include/isa.h            opcode set, addressing, header flags
    limbo/types.c sizing     IBY2WD-relative layouts, descriptor maps
    limbo/types.c sign()     MD5 interface signatures (interop!)
    frame protocol           REGLINK/REGFRAME/REGMOD/REGTYP slots
    exception table format   only if/when Ember surfaces exceptions

What Ember never touches:

    libinterp/xec.c, gc.c, heap.c    emu/port/dis.c (scheduler)
    comp-*.c (JIT)                   dlm-*, devdynld, builtin C modules
    Styx/9P, namespaces, devices     anything under os/

---

## 10. How Ember reaches Dis (decision)

Three options were considered:

**(a) Textual transpile Ember -> Limbo source.** Rejected. Loses source
positions (bad errors, bad .sbl), fights Limbo's expression-level
restrictions, and makes closure/match lowering fragile as strings.

**(b) Elaborate into Limbo's internal `Node`/`Decl`/`Type` trees and call
the limbo middle end (`typecheck()` + `modcom()`).** Considered and
rejected after review. The seam looks small (replace `yyparse()`,
populate `tree`/`impmods`), but the limbo middle end is not a library:
it is ~40 files of shared mutable globals (`limbo.h:586-682`) coupled to
the yacc lexer, it re-runs its own type checking with Limbo's rules (so
Ember constructs must round-trip through a second, foreign type system),
and every Ember lowering would be constrained by what Limbo's checker is
willing to re-accept. That coupling would leak Limbo semantics into
Ember's design permanently.

**(c) Ember compiles to Dis directly, using limbo as the reference
implementation (chosen).** Ember owns its full pipeline:

    Parse -> Resolve -> Type check -> Elaborate -> Core IR -> Lower -> Dis

Dis is a small, stable, documented target (`man/6/dis`, `doc/dis.ms`,
section 3 above); the loader `libinterp/load.c:parsemod` is an executable
specification of what Ember must emit. The limbo sources are kept open on
the desk, not linked in. The contracts Ember re-implements, each with its
reference:

Ember's output does **not** have to match limbo's — the goal is a better
language, and better generated code is welcome. Identity is required only
at the boundaries the VM and existing modules can observe. Everything
else is graded on behavior, not on resemblance to limbo's output:

*Must be exact (interop/VM contracts):*

| Contract | Reference | Verification |
|---|---|---|
| interface signatures | `limbo/types.c:sign`, `rtsign` (MD5 via libsec, XOR-folded) | Ember's sig for a `.m` function equals limbo's; tested by loading Ember modules from Limbo callers and vice versa |
| layout of interop-visible types (args/results/adts crossing a module boundary) | `limbo/types.c:sizetype`, `sizeids` | round-trip values through a Limbo module and back |
| GC pointer maps (correct, not identical) | `limbo/types.c:descmap`, `mktdesc` | soak under `emu` with GC stress; every ref slot marked, no word mismarked |
| frame protocol | `REGLINK..REGRET` (isa.h:219), `limbo/com.c:fncom` | call into and out of Limbo modules |
| `.dis` encoding validity | `libinterp/load.c:parsemod` | loader accepts; `disdump` round-trips |

*Free to differ (and to improve):*

- instruction selection, temp allocation, branch layout — `gen.c`/
  `optab.c` show what the VM executes well, nothing more;
- internal (non-exported) data layout and calling conventions between
  Ember-only functions;
- how much dead-store cleanup happens (limbo's `optim.c` is a reference
  for later, not a bar to clear now).

Differential testing against `limbo` therefore compares *behavior* under
`emu` (interpreted `-c0` and JIT) plus the exact-contract rows above; it
never diffs code sections byte-for-byte. The signature function is the
one piece ported verbatim, because interop depends on bit-equality, not
on similarity.

The Ember AST (in `ember/ember.h`) still deliberately follows Limbo's
node discipline (single Node, `O*` ops, `Oseq` lists, `Src` spans,
interned `Sym`s) — now purely so the two compilers stay easy to read side
by side while porting logic.

### Lowering plan (all in the Ember compiler; no Dis changes)

| Ember construct | Lowers to (Dis-level, following limbo's encoding) |
|---|---|
| `struct` | flat adt layout; value or heap `INEW`+descriptor by use |
| `pick` ADT / `Option` / `Result` | ref cell with leading tag word, per-arm layouts; same shape `limbo/types.c:2174` produces |
| `match` + exhaustiveness | checked in Ember's type checker; compiled to `ICASE` on the tag word |
| `?` | generated control flow: tag test, Ok arm continues, Err arm re-wraps and `IRET` |
| generics | monomorphization in elaboration; one Core IR decl per instantiation, names mangled `f$int$string` |
| closures | lambda lifting: env adt + lifted top-level fn; escaping values are `(env, (module,index))` pairs called via `IMFRAME`/`IMCALL` |
| multiple returns | tuple layout (flat bytes), as limbo does |
| `chan`/`<-`/`spawn` | `INEWCW...`, `ISEND`/`IRECV`, `ISPAWN` |
| `import x "y.m"` | Ember reads the `.m` interface (small Limbo-interface parser in the resolver), emits LDT imports with matching sigs, `ILOAD` at load site |
| `load M path` | `ILOAD` + `linkmod` LDT, verbatim semantics |

### Interop answer (hard requirement from the brief)

Ember modules **can** expose legacy-compatible interfaces, because a
`.dis` export is nothing but (name, pc, frame descriptor, MD5 type sig).
An Ember function whose type matches a `.m` declaration — with Ember
computing the signature exactly as `limbo/types.c:sign` does — is
loadable from existing Limbo callers with full type checking, and vice
versa. The only Ember constructs invisible to Limbo callers are those
that do not exist in Limbo's type grammar (Ember generics
pre-instantiation, closure types); exported (interface) functions are
therefore restricted to Limbo-expressible types — the same restriction Go
places on exported C ABI, and no loss versus today.

---

## 11. Reuse decisions: attempted, adopted, rejected

| Subsystem | Decision |
|---|---|
| Dis ISA, VM, scheduler, GC, loader | untouched (per brief; no limitation found) |
| Dis object format, frame protocol, descriptor maps, LDT/link model | **reused as-is** — Ember targets them directly; `libinterp/load.c:parsemod` is the acceptance test |
| limbo compiler code (com/ecom/gen/optim/dis/sbl) | **reference implementation, not linked**: Ember compiles to Dis itself; limbo's middle end is a tangle of shared globals coupled to its yacc lexer and re-runs Limbo's own type rules, so linking it in would leak Limbo semantics into Ember (section 10, option b) |
| limbo sign() algorithm | **ported verbatim** (canonical type string + MD5 fold, libsec) — interop requires bit-equality |
| limbo layout/descriptor logic | **ported as reference**: layouts must be identical only for interop-visible types (values crossing a module boundary); Ember-internal layout is free to differ, checked for correctness (GC soak), not for resemblance |
| limbo yacc grammar/lexer | **not reused** for Ember source: Ember needs Go-style ASI, `match`, `?`, generic brackets; grafting these onto the LALR grammar was tried on paper and produced conflicts around `[`/index vs type-args and `{` composite literals vs blocks. A hand recursive-descent parser (as Go itself uses) is ~1.4k lines and self-contained (`ember/parse.c`) |
| `.m` interface files | **reused as the interop surface**: Ember's resolver parses `.m` module declarations (a small, stable subset of Limbo syntax) to type imports and compute signatures; no new interface format |
| Limbo polymorphism (dictionary passing) | **not used** for Ember generics (brief mandates monomorphization; erasure also cannot type Ember's `func` values); interop with polymorphic Limbo APIs deferred until a concrete need appears |
| Limbo exceptions | not surfaced in Ember M1 feature set; `Result`/`?` are plain values; handler-table emission reserved for interop |
| Dis changes | none proposed; the six-point justification protocol in the brief was not triggered anywhere |

---

## 12. Where Dis is not expressive enough (watch list)

Dis was designed for Limbo, and Ember is a bigger language. Every gap
below has a workable front-end lowering today — none currently justifies
a VM change under the six-point protocol — but honesty requires naming
them, with the cost of the workaround and what evidence would reopen the
question. This is the list to benchmark against as real Ember programs
appear.

**12.1 Function values carry no environment.** Dis's only first-class
function value is the two-word `(Modlink, index)` pair (`tfnptr`,
limbo/types.c:209); the call ops (`IMFRAME`/`IMCALL`) have no slot for
captured state. Ember closures therefore lower to an `(env adt, fnref)`
pair: one heap allocation per escaping closure, one extra argument per
call, and closure-typed fields are two words wide. *Would reopen if:*
closure-heavy Ember code shows the extra allocation/indirection
dominating profiles. The minimal compatible change would be a call op
that loads an env pointer from the function value — but segmented frames
and the JIT make this a real VM project, so it waits for the benchmark.

**12.2 No parametric code sharing.** Type descriptors are concrete
(size + pointer bitmap); one compiled body cannot serve two
instantiations whose pointer maps differ. Ember's choices are
monomorphization (chosen: code-size cost, no runtime cost) or
Limbo-style erasure with dictionaries (runtime cost, no first-class
`func` typing). Dis offers no reified type parameters and no
descriptor-polymorphic allocation. *Would reopen if:* monomorphized
`.dis` size becomes a deployment problem (Dis modules are usually tens
of KB; measure before worrying).

**12.3 No unsigned and no sub-word integer arithmetic.** Dis arithmetic
is signed `byte`/`word`/`big`/`real` (isa.h opcode families); there are
no unsigned ops (`byte` aside) and no 16-bit type. Ember M1 simply adopts
Limbo's numeric model. If Ember later wants `u32`-style types for systems
code, they must be emulated with masks and sign-fixups. *Would reopen
if:* emulation shows up in real workloads (e.g. hashing, codecs) — the
classic fix is a handful of unsigned compare/shift/divide ops.

**12.4 No tail-call instruction.** `ICALL`/`IMCALL` always push a frame;
deep mutual recursion relies on segmented stack growth
(`libinterp/stack.c`), which is graceful but not O(1). Functional-style
Ember code (state machines as recursive functions) pays for it. Front-end
loopification covers self-tail-calls; mutual tail calls remain frames.
*Would reopen if:* real programs hit stack/perf limits that loopification
cannot reach.

**12.5 No runtime type information beyond pointer maps.** `Type`
(interp.h:201) knows sizes and where the pointers are — no field names,
no arm names, no dynamic type tests. Consequences: no reflection, no
generic printing (`sys->print` formats are compiler-checked instead),
and Ember `interface`-style dynamic dispatch (post-M1) must be lowered
to fat values carrying explicit method tables built by the compiler.
This is a deliberate Dis virtue (small, checkable) as much as a gap;
Ember follows the same philosophy and generates what it needs statically.

**12.6 Exhaustiveness and tag safety are compiler-only.** `ICASE` is an
integer range dispatch; nothing in the VM prevents reading arm B's fields
while the tag says A — the loader trusts the compiler (as it does for
Limbo). Ember's `match` checker is therefore load-bearing for safety,
and Ember never emits unguarded arm access. A checked-tag instruction
would move this guarantee into the VM, but Limbo has lived without it
since 1996; no evidence yet says Ember can't.

**12.7 No map/hash primitive.** Not in Ember's M1 feature set; noted
because Go programmers will ask. The Inferno answer is a library
(`appl/lib/hash.b`); Ember can ship a generic `Map[K,V]` in its prelude
by monomorphizing over that pattern. No VM involvement.

None of these blocks the initial feature set: modules, imports, structs,
arrays, strings, functions, closures, inference, ADTs, match, Option,
Result, `?`, generics, channels, and spawn all lower cleanly onto Dis as
it stands. The gaps shape *how* they lower (12.1, 12.2), not *whether*.

---

*Prepared as the Phase 0/Milestone 1 study for Ember. Line numbers refer
to the tree at the time of writing and drift with edits; identifiers are
stable search anchors.*
