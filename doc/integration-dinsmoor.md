# Dinsmoor Inferno64 technical decision study

Reference: `dinsmoor/master` at `6563393c8b4501ee88e0619eda20d6bc156ebe95`.
Study base: `inferno-rio` at `704c0c07e`.

This studies why Dinsmoor replaced core pieces and what those decisions teach
us. It is not an import request. Although 8,560 paths overlap and 7,720 are
byte-identical, the remaining changes concentrate at incompatible ABI and
product boundaries.

## LP64 preserves the language contract

Dinsmoor keeps Limbo `int` and a Dis word at 32 bits while making pointers 64
bits. The stated reason is source portability: integer range, overflow,
structure layout, and wire behavior should not change with host address width.
The ILP64 experiment is kept on another branch instead of blurring the main
ABI.

Classic Inferno often used `WORD` both for a Dis word and for storage capable
of carrying an address. LP64 separates:

- `IBY2WD`: four-byte language/Dis word;
- `IBY2PTR`: four- or eight-byte reference/frame slot.

Compiler temporaries, frame headers, module globals, case tables, `alt`, GC
maps, loaders, builtins, and JIT moves must use the right unit. The history is
a catalog of defects from choosing the wrong one. This base instead made more
VM words and alignment pointer-sized. Dinsmoor is coherent, but adopting it is
an ABI conversion, not a pointer-safety patch.

Useful work is to specify the language data model separately from the C host
model and audit boundaries in those terms. A comparative benchmark corpus can
measure language-visible behavior, frame/heap size, and JIT cost. Do not mix
LP64 compiler or JIT hunks with the current frame layout.

## Module magic identifies both widths

Dinsmoor assigns independent module-magic bits to pointer width and word width,
distinguishing classic 32/32, LP64 64/32, and ILP64 64/64. The loader rejects
mismatches and the shell may rebuild trusted source.

Pointer width alone cannot distinguish Dinsmoor modules from this line's
64-bit-word format. Both have 64-bit addresses but different frames, globals,
GC maps, and integer representations. Silent acceptance becomes memory
corruption.

The concept transfers: document an ABI identity covering pointer width, word
width, alignment, and opcode/layout extensions, then emit a named loader error.
Automatic rebuilding is safe only when source and toolchain provenance are
unambiguous; otherwise stop at rejection.

## Tests arose from concrete width failures

C unit tests, narrowing lint, sparse annotations, heap checks, Dis scenarios,
JIT equivalence, and stale-bytecode guards correspond to observed failures:
implicit declarations truncating pointers, pointer moves through 32-bit temps,
stale Dis, bad GC maps, sign extension, wrong exception/global slots, and
interpreter/JIT width disagreement.

This provenance is more valuable than copying expected values. Port the harness
in layers: width-neutral base-library tests first, VM assertions rewritten from
the local ABI specification second, then narrowing/address-space analysis with
a reviewed baseline. Require a deliberate negative control before crediting a
test with coverage.

## Fresh builds enforce coherence

Dinsmoor wraps `mk` and nukes before full builds because incremental builds
allowed compiler, emulator, and Dis artifacts from different ABIs to coexist.
Those failures resembled runtime corruption.

The decision is to make compiler/runtime/bytecode coherence an invariant.
Always rebuilding is reasonable while cheap; a build stamp can support safe
incrementality only if it covers every ABI-affecting input. Keep `mk`
authoritative—a wrapper may orchestrate it but must not create another build
graph.

## The platform matrix keeps missing evidence visible

`make check` records required, skipped, and TODO cells across platform,
configuration, and execution mode. A green suite can no longer mean that
headless, JIT, native, or another architecture simply never ran.

This directly suits a repository with many hardware and research branches.
Adapt the idea, not its manifests. Each claimed platform should name its build,
test, last verified revision, and whether evidence is local, CI, or hardware.

## Tk was extended instead of replaced

Dinsmoor added geometry, events, fonts, validation, undo, and themed widgets
while reusing classic cores, then migrated applications and added headless
render baselines. This preserves the existing application ecosystem and makes
modernization incremental.

It contrasts with InferNode's replacement UI. The technical question is whether
missing primitives or synchronous remote-I/O behavior is the actual constraint.
Evaluate `after`, `place`, virtual events, undo, themes, resize, and widgets
independently. Screenshot tests must pin renderer, fonts, dimensions, and a
discriminating pixel metric.

## Charon moved to a retained, testable model

Dinsmoor introduced a retained DOM, render-from-DOM, live handlers, CSS/layout,
canvas, compression/chunking, cookie rules, resize, and fixture-based tests. The
sequence matters: representation and dispatch were separated before features
were layered on.

Retaining the document model enables mutation, event lifetime, reflow, and
testing. Port coherent phases with fixtures rather than isolated CSS tokens.
Keep network transport on local `tls12(2)`/`https(2)`, not a second TLS
stack.

## Vendored C compensates for Inferno's execution boundary

Dinsmoor links mbedTLS, FFmpeg, WebP, stb, and other C into hosted `emu`.
Inferno has no conventional native-C userspace: C joins the trusted
emulator/kernel while applications are Dis. A builtin is therefore the direct
route to modern codecs, images, crypto, or 3D.

The tradeoff is a larger TCB, host/native disparity, upstream maintenance,
licensing, and frozen builtin APIs. Prefer remote 9P services when latency and
data movement permit; use a builtin only when measurement justifies it. Do not
vendor 272 mbedTLS files for operations local `libsec` already supplies.

## The native-application limit is an important negative result

Dinsmoor explicitly concludes that applications requiring arbitrary modern C
libraries do not fit naturally in native Inferno. Adding protected POSIX C
userspace would turn it into another OS. The architectural choices remain
Limbo/Dis, a narrow audited builtin, or a remote file service.

That is a useful filter: software requiring a POSIX process, ELF ecosystem, and
broad syscall surface should usually stay remote behind 9P rather than recreate
POSIX inside Inferno.

## Decision table

| Decision | Treatment | Reason |
|---|---|---|
| LP64 language model | Benchmark/document | Coherent but incompatible ABI |
| Two-dimensional ABI magic | Adapt concept | Prevents 64/32 vs 64/64 confusion |
| Stale-Dis rejection | Adopt concept | Turns corruption into a build error |
| LP64 compiler/VM/JIT | Reject as import | Cannot mix layouts |
| C/Dis test layers | Port selectively | Captures real failure classes |
| Narrowing/sparse gates | Prototype | Valuable with reviewed baselines |
| Capability matrix | Adapt | Makes absent testing visible |
| Fresh-build wrapper | Adapt orchestration | Coherence benefit; `mk` stays authoritative |
| Tk extensions | Evaluate separately | Incremental, limited-risk modernization |
| Retained-DOM Charon | Port by phase | Representation enables real browser behavior |
| mbedTLS | Exclude | Competing TLS/crypto stack and large TCB |
| FFmpeg/WebP/stb | Decide by measurement | Performance vs TCB/portability |
| Raylib/raster3 | Compare with Metal draw3d | Avoid duplicate unmeasured architectures |
| Native patches | Study on owning branches | Protect active `os/` work |

The first experiment should be ABI coherence plus a small test slice: document
local widths, add an explicit module identity/rejection test, and port
width-neutral C tests with negative controls. That evaluates Dinsmoor's best
technical decisions without presuming its ABI is the answer.
