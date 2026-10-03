# InferNode technical decision study

Reference: `infernode/master` at `d0a175dbf559c5d1f400d1722e84b5de450afb25`.
Study base: `inferno-rio` at `704c0c07e`.

This is not an import list. It asks why InferNode replaced parts of Inferno,
which constraints shaped the replacement, and which decisions are worth
testing here. The repositories have no merge base; a tree merge would delete
hundreds of active files.

## Distribution boundary, not source deletion

InferNode began as a small hosted distribution for servers and embedded
systems. Its removal of native kernels, Tk/Prefab, examples, fonts,
filesystems, and applications reduced the supported and packaged surface.
Later, concrete product needs brought back SDL3, mobile packaging, Tk, a Pi
kernel, Bluetooth, and other hardware.

The transferable decision is to define checked release profiles. This tree can
have hosted-headless, hosted-GUI, native-board, and development manifests
without deleting its broader source base. The deletions solved product scope,
not defects in the deleted subsystems.

## LP64 and the cost of width ambiguity

InferNode describes a Dis word as signed 32-bit while C `WORD` storage is
pointer-sized. Its loader sign-extends 32-bit `DEFW` values into wider slots;
`STRUCTALIGN` is `sizeof(int)`, unlike this base's pointer-sized alignment.
Later fixes distinguish pixels, wire words, Limbo integers, VM slots, pointers,
and native allocator words.

The motivation is traditional 32-bit Limbo `int` semantics plus safe 64-bit
host pointers. The cost is permanent width discipline across `alt`, Draw,
module loading, GC maps, networking, builtins, and every JIT. This base made
more VM layout pointer-sized, so adopting InferNode's typedefs or alignment is
an ABI conversion, not a modernization patch.

Useful lessons:

- specify language word, pointer, slot, wire, pixel, and alignment widths;
- encode enough ABI identity to reject incompatible Dis modules;
- test sign extension and fixed-width formats on 64-bit hosts;
- compare interpreter and JIT behavior.

Do not mix InferNode compiler/JIT/layout hunks into this ABI.

## The JIT became normal execution

InferNode enabled the JIT in release paths and exercised it on hosted
AMD64/ARM64, Windows, RISC-V, and bare metal. Recent fixes cover compiled
bounds checks, faults becoming Limbo exceptions, cross-mode calls, module
unload, destructor paths, stack alignment, freed compiled types, and arithmetic
traps. These exist because benchmarks did not establish semantic equivalence.

Turn each fix into a behavior-level probe against this tree's interpreter and
JITs. Import invariants and reproducers, not backend code: this tree's
multicore executor and parallel GC have different lifetime and safepoint rules.

## 9P services make the namespace the authority

`llmsrv`, `tools9p`, audit, wallet, browser control, and Matrix are small 9P
trees rather than SDKs or private RPC. Mounting therefore chooses both provider
and authority; a child can receive one subtree without the full catalogue.

Reusable decisions include file-interface-first design, clone/session
directories, text records, control files, location-independent mounts, and
delegating factotum operations instead of keys.

The long hardening history is equally important. Open descriptors, environment,
devices, host bridges, process control, writable ancestors, delimiters, and
mount controls can escape a nominal path allowlist. InferNode added fail-closed
setup, FD hiding, read-only mounts, per-tool attenuation, fixed namespaces, and
traversal tests because “authority is the namespace” was not automatically
true.

Before porting an agent, build a confinement laboratory covering inherited FDs,
devices, environment, `#C`, `/prog`, writable mount points, traversal, and
nested delegation under local multicore process-group semantics.

## Proposal and commit use different authorities

Wallet, messaging, editor, and other effect paths evolved after signing-oracle
and confused-deputy problems. Agents now create inert typed proposals; a
controller in another namespace owns approval and commit. The agent cannot
manufacture approval because it cannot name the approving surface.

This pattern is useful for file mutation, messages, deployment, and device
control. Adopt the design for the first mutating agent tool. The cryptocurrency
and x402 implementation remains out of scope unless payments are a requirement.

## Formal verification protects the chokepoint

InferNode models namespace copying, isolation, reference counts, locking,
export boundaries, and selected C routines with TLA+, SPIN, and CBMC. This is
rational because one verified confinement chokepoint replaces many policy
checks. The models are bounded and depend on abstraction/stub fidelity; they
describe InferNode's implementation, not this tree's multicore one.

Port one property at a time. Each model must name the exact local functions and
commit represented, include concurrent executors where applicable, and fail
against a deliberately weakened implementation before entering CI.

## SDL3 addresses portability and packaging

SDL3 unifies window, input, and audio behavior across Metal, Vulkan, D3D,
Android, and iOS. It also supplies HiDPI, safe-area, soft-keyboard, touch, and
packaging behavior. Queue-depth, fork initialization, stride, Retina, safe-area,
and keyboard-inset fixes in its history are useful requirements.

Add it only as another configured hosted backend. Do not replace Metal or X11
without measuring latency, damage, scaling, input fidelity, audio drain, and
package size.

## Xenith and Matrix are workflow experiments

Xenith moves blocking Acme operations behind asynchronous I/O for remote 9P.
Matrix makes text composition plus a mounted control tree the application
assembly mechanism. The reusable ideas are the async boundary and inspectable
composition, not necessarily either complete UI. First measure existing Acme/Tk
on delayed mounts and prototype the composition grammar against current
modules.

## Crypto and release work follow the threat model

Post-quantum auth, factotum/secstore integration, signed releases, SBOMs,
fuzzers, and provenance follow from handling agent credentials and publishing
binaries. The release manifest and provenance machinery are independently
useful. Crypto imports need known-answer, interoperability, allocation, and
constant-time review; do not replace `libsec` or add a second TLS stack.

## Decision table

| Decision | Treatment | Reason |
|---|---|---|
| Checked release profiles | Prototype | Smaller supported surface without deleting source |
| Explicit ABI identity | Investigate | Prevent silent 64-bit ABI confusion |
| InferNode LP64 VM/JIT | Reject as import | Fundamental layout conflict |
| JIT exception/lifetime probes | Adapt | Behavior applies across backends |
| Namespace construction | Prototype first | Central security claim must survive local semantics |
| Minimal read-only LLM/tool service | Port after confinement | Tests 9P architecture with low authority |
| Proposal/commit split | Adopt as design | General irreversible-effect boundary |
| Formal models | Rewrite against local C | Imported proof claims would not correspond |
| SDL3 | Optional parallel backend | Portability without losing optimized paths |
| Xenith/Matrix | Experiments | Useful ideas, not dependencies |
| Wallet/x402 | Exclude | Product policy outside platform goals |
| PQ crypto | Separate review | High assurance burden |
| GoDis | Exclude | Removed from current master |
| Native/BT/PCI/USB branches | Compare on owning branches | Protect independently advanced work |

The first experiment should be a confinement laboratory: a namespace builder,
one harmless read-only 9P service, parent/child attenuation, and adversarial
escape probes. That tests InferNode's most interesting decision before its
application stack pressures us to assume the decision transfers.
