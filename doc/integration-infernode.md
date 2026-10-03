# InferNode integration audit

Reference: `infernode/master` at `d0a175dbf559c5d1f400d1722e84b5de450afb25`.
Integration base: `inferno-rio` at `704c0c07e`.

The histories have no Git merge base.  This branch is therefore an integration
queue, not a merge of `infernode/master`.  Whole-tree merges are prohibited:
against this base InferNode deletes 923 `os` files, 91 `emu` files, 261
`appl/cmd` files, 118 `appl/lib` files, and 123 module interfaces.  Those
deletions are distribution differences, not changes to adopt.

## Include, after adaptation

### 1. Namespace-security specification and tests

Start with `formal-verification/`, `appl/cmd/nsaudit.b`, and the namespace
boundary tests.  Preserve the models as imported evidence, but do not claim
that they verify this tree until their C correspondence tables have been
rewritten against this tree's `pgrp`, namespace, exportfs, and multicore code.

Acceptance:

- every model names the exact local C functions and commit it represents;
- SPIN, TLC, and CBMC run in CI;
- at least one deliberately weakened local implementation makes each relevant
  harness fail;
- multicore namespace mutation is represented, rather than assuming one Dis
  executor.

### 2. Veltro as an optional userspace subsystem

Candidate paths are `appl/veltro/` (69 files), `appl/cmd/llmsrv.b`, and the
small supporting libraries and module interfaces they actually import.  Port
from leaves inward; do not copy all 77 new module interfaces or all 119 new
commands as a dependency shortcut.

The first usable slice is headless and local:

1. LLM service mounted at `/mnt/llm`;
2. read/list/find tools over an explicitly constructed namespace;
3. one coordinator and one attenuated child;
4. an audit file showing the namespace and tool grants;
5. adversarial traversal, inherited-fd, device, and prompt-injection tests.

Network tools must use this tree's `tls12(2)` and `https(2)`, never host
commands through `#C`.  No wallet, browser, GUI, or MCP bridge is required for
the first slice.

### 3. Release and build-product verification

Adapt, rather than copy, the Dis manifest check, fuzz jobs, SBOM generation,
and release provenance from the 16 InferNode workflows.  Keep this tree's
existing smoke workflows and build commands.  A workflow that references
InferNode's reduced directory layout is not evidence here.

### 4. SDL3 and Android as independent ports

The SDL3 and `android-app/` work is useful as a new hosted display/input port.
It must not replace Cocoa/Metal, X11, or native draw acceleration.  Keep it
behind an Inferno configuration and runtime selection rather than platform
`#ifdef` proliferation.

### 5. Selected cryptography

ML-KEM, ML-DSA, SLH-DSA, secp256k1, Keccak, and AES-GCM are candidates only as
small, independently reviewed imports with known-answer tests and constant-time
tests.  Do not replace `libsec` wholesale: 12 existing files differ, four local
files disappear in InferNode, and this tree already has modern TLS and Bluetooth
crypto work that InferNode's layout does not preserve.

## Evaluate separately

- Xenith (120 files): useful async Acme ideas, but an application fork, not a
  prerequisite for agents.
- Matrix (22 files): attractive 9P composition interface; assess after the
  headless agent slice establishes the service conventions.
- Web, mail, PDF, SVG, AVIF, WOFF2, and multimedia additions: take one library
  at a time with fixtures and license review.
- Bare-metal, Bluetooth, PCI, USB, GIC, and Raspberry Pi topic branches: compare
  as patches against the corresponding local branches.  Do not route them
  through this userspace integration branch.

## Exclude

- Whole-tree merge or replacement of `os/`, `emu/`, `libinterp/`, `appl/`, or
  `module/`.
- InferNode's ABI/JIT as a replacement for the current JIT, multicore VM, or
  parallel-GC work.
- Wallet, x402, ERC-20, and payment approval code unless payments become an
  explicit product requirement.
- Branded Lucia/Lucifer desktop as an agent-runtime dependency.
- Checked-in Dis bytecode or release binaries.
- GoDis: current `infernode/master` documents it but contains no `tools/godis`
  source directory.

## Import order

1. Verification tools and adapted namespace models.
2. Namespace construction plus negative security controls.
3. Minimal `llmsrv` and read-only tool service.
4. Coordinator and attenuated sub-agent.
5. Mutating tools with audit and approval boundaries.
6. Optional Matrix, Xenith, SDL3, Android, and cryptographic additions as
   separate commits and independently reversible features.

No source from InferNode has been imported on this audit commit.  That is
deliberate: its security claims depend on adapting the model-to-code mapping,
and its distribution-level tree cannot be merged without deleting active local
work.
