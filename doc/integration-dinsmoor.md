# Dinsmoor Inferno64 integration audit

Reference: `dinsmoor/master` at `6563393c8b4501ee88e0619eda20d6bc156ebe95`.
Integration base: `inferno-rio` at `704c0c07e`.

The histories have no Git merge base, although 8,560 paths overlap and 7,720
of those paths have identical blobs.  Dinsmoor is an LP64 fork (64-bit pointers,
32-bit Limbo `int`); this tree's 64-bit line has different ABI choices and has
continued into multicore, JIT, native-port, and parallel-GC work.  Treat the
repository as a source of tests and separable applications, not as a runtime
merge target.

## Include, after adaptation

### 1. Layered test gate

Port the structure and useful cases under `tests/`, not the directory as one
copy.  The high-value pieces are:

- C unit tests for lib9, libbio, libdraw, libinterp, libmath, libmemdraw,
  libmp, and libsec;
- Dis VM suites for execution, concurrency, crypto, Styx, loading, exceptions,
  globals, and image I/O;
- JIT interpreter-equivalence checks;
- QEMU native-kernel console tests;
- narrowing lint and sparse/static-analysis gates;
- platform manifests that keep unsupported cells visible;
- headless Tk render baselines.

Each imported test must first be run against the local implementation.  A test
whose expected values encode LP64 layout is rewritten from the local Dis ABI
specification, not changed merely until it passes.  New tests must also be seen
to fail under a deliberate negative control before being credited as coverage.

### 2. Developer entry point

Adapt the `make check` capability matrix and fresh-build wrapper as convenience
front ends to this tree's `mk` rules.  They must not introduce a second build
graph or make GNU make authoritative.  Existing per-branch build and smoke
workflows remain the source of truth.

### 3. Documentation, selectively

The subsystem guides under `docs/ON_*.md` are useful review checklists.  Import
only documents that are reconciled line by line with this tree.  In particular,
JIT, ABI, GC, kernel, graphics, and build claims differ and cannot be copied as
current documentation.

### 4. Independent userspace candidates

Good isolated candidates are:

- Charon CSS/DOM/dechunk/gzip improvements;
- readline and terminal modules;
- image animation/loaders and WebP wrappers;
- newer Tk widgets, theming, cursors, and workspaces;
- Fediverse and Bible file servers;
- OBJ/raymath/raster3 applications;
- live X11 resize, compared with the existing resize branch.

Each is a separate commit with its own fixtures and man page.  Network clients
must use local `tls12(2)`/`https(2)`, not Dinsmoor's bundled TLS as an implicit
transport replacement.

## Evaluate separately

- FFmpeg: useful codec surface, but the tree includes a large upstream archive
  and a kernel-facing wrapper; prefer a reproducible external-source recipe.
- WebP and stb: small wrappers are plausible, but retain upstream notices and
  use system/upstream sources rather than casually vendoring generated bulk.
- mbedTLS: 272 new files and a competing TLS/crypto stack.  Consider only for a
  narrowly defined interoperability or oracle role.
- Raylib-style 3D: compare against the existing Metal draw3d path before
  introducing a second rendering architecture.

## Exclude

- LP64 compiler, VM, Dis layout, JIT, pointer checks, or ABI markers as a
  wholesale replacement.
- Whole-tree merges of `libinterp` (29 conflicting files), `emu` (80), `os`
  (139), `appl/cmd` (57), `appl/lib` (29), or `module` (23).
- Vendored mbedTLS and FFmpeg source by default.
- Dinsmoor's native-kernel changes through this branch; native `os/` work is
  maintained separately and must be compared on its owning branches.
- Pre-rendered screenshot baselines without a reproducible renderer, font set,
  dimensions, and pixel-difference rule.
- Documentation that describes the LP64 fork as though it describes this tree.

## Import order

1. C unit-test harness and base-library tests.
2. Dis VM tests and JIT equivalence gate.
3. Lint, sparse, and platform capability manifests.
4. QEMU native tests, on the native-port owning branch rather than here.
5. Charon, Tk, terminal/readline, and image improvements one subsystem at a
   time.
6. Optional multimedia or 3D integrations only after choosing one dependency
   and rendering strategy.

No Dinsmoor runtime source has been imported on this audit commit.  Importing
its LP64 core would turn this into an ABI conversion rather than an integration
and would overwrite newer local runtime work.
