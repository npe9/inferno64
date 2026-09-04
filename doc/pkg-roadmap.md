# Roadmap: Upspin + Vanadium → a searchable package manager

The single spanning plan. It takes *every* component of Upspin and
Vanadium, maps each to what this tree already has, and sequences the gaps
into a dependency-ordered path whose end state is a package manager you
can **search**. The three companion docs are the inputs: `doc/package-
management.md` (the concept), `doc/vanadium-upspin-survey.md` (component-
by-component state), `doc/remaining-plan.md` (unrelated loose ends). This
doc is the ordered build.

## Thesis

A package manager is three layers, and Upspin and Vanadium each supply
two of them, over Inferno's namespace:

1. **Naming** — a global namespace where a package name resolves and can
   be *walked*. Vanadium's mount tables ≅ Inferno Styx mounts + `registry(4)`.
2. **Trust** — who published a package and whether to believe it.
   Vanadium blessings (delegable, caveated) + Upspin's KeyServer identity.
3. **Content** — signed, content-addressed, optionally-encrypted bytes.
   Upspin's DirServer/StoreServer + Inferno's `venti` CAS + EE packing.

The package manager is a client that walks the naming layer, verifies via
the trust layer, fetches from the content layer, and installs by
`tarfs`+`bind`. **Search is not a fourth thing bolted on** — it is what
the naming layer gives you (browse by walking) plus an index over the
content layer's metadata (query) plus Vanadium discovery (find the
repositories themselves). So search falls out of the same layers, which
is why this plan reaches it rather than special-casing it.

## Component ledger

Every Upspin and Vanadium piece, its layer, and its state here.

### Vanadium

| Component | Layer | State |
|---|---|---|
| Principals (keypairs) | trust | **Have** (v23, built, source recovered) |
| Blessings (cert chains) | trust | **Have** |
| Caveats | trust | **Partial** — const/expiry only |
| Blessing patterns + `authorize` (ACL) | trust | **Have** |
| Secure RPC (mutual blessing auth) | trust/transport | **Have** (framed over `msgio`) |
| Naming / mount tables (Namespace) | **naming** | **Build** — on `registry(4)` + Styx |
| Discovery (advertise/scan) | **naming (search)** | **Build** |
| Third-party caveats + discharges | trust | **Build** (revocation/audit) |
| VOM encoding | interop | **Build** (only for Go `v.io`) |

### Upspin

| Component | Layer | State |
|---|---|---|
| Content-addressed StoreServer | content | **Have** via `venti` (SHA-1; want SHA-256) |
| EE packing primitives | content | **Have all** (AES-GCM, ECDH, sign, hash) |
| EE packing *logic* | content | **Build** (compose the primitives) |
| Global naming `user@domain/path` | naming | **Build** — on the same naming layer |
| KeyServer (identity → key) | trust | **Build** |
| DirServer (name → entry, blocks, keys, sig) | content/naming | **Build** — Styx over venti |
| Access files (ACL) | trust | **Have an engine** — reuse blessing patterns |
| Client (upspin / upspinfs) | — | subsumed by the `pkg` client |

The pattern: the **trust layer is essentially done** (v23), the
**content store exists** (venti), and every **crypto primitive is
present**. The genuine build is the **naming layer** (shared by both
systems and by search) and the **content services** (DirServer,
packing) that sit on it.

## The roadmap

Dependency-ordered. Each phase names what it builds, what it reuses, and
how it is shown to work (negative control where it matters).

**Phase 0 — Foundations. DONE.** v23 security+RPC recovered, building,
selftest passing. Crypto primitives and `venti` CAS present.

**Phase 1 — Naming layer.** *The keystone; everything else and all of
search depend on it.* A Styx service serving a package namespace
`/pkg/<category>/<name>/<version>/`, resolving by `walk`, mountable
locally and over secured Styx (the encrypted transport already shipped).
`registry(4)` backs the dynamic set of what's published. This is
Vanadium's mount table expressed as Styx, and simultaneously the root of
Upspin's global naming. *Verify:* `ls /pkg/net`, `walk /pkg/net/ssh`
resolve against one repo; a remote mount carries ciphertext.

**Phase 2 — Content layer.** SHA-256 `venti` scores (or a thin CAS).
A **DirServer**: a Styx service mapping a package name to its manifest (a
`proto` + header: version, content-hash, signature, deps), backed by
venti Root/Entry blocks. A **StoreServer** fetch path: content-addressed
blobs by hash from venti or an https mirror. *Verify:* a name resolves to
a manifest, the manifest's hash fetches the exact tar, a corrupted blob
fails the hash check (negative control).

**Phase 3 — Trust layer.** Publisher **blessings**: the publisher signs
the manifest; the chain roots at a repo blessing you trust; `factotum`
holds the roots. A **KeyServer**: identity → public key, a signed key log
served over Styx/https. *Verify:* a valid chain installs; a wrong,
unknown, or expired-caveat blessing is rejected (negative control) —
this exercises the caveat path too.

**Phase 4 — The package manager.** A `pkg` client: resolve a name
(phase 1) → verify the blessing (phase 3) → fetch the blob (phase 2) →
`tarfs`+`bind` install. Dependency-closure resolution over the naming
layer. A content-addressed **lockfile** → a reproducible namespace.
*Verify:* `pkg install net/ssh` end to end; `pkg list`; uninstall =
unbind; upgrade = swap bind; a lockfile replays an identical namespace.

**Phase 5 — Search.** *The explicit goal; see the next section for the
three mechanisms.* Build the query index and wire in discovery. *Verify:*
`pkg search tls` returns ranked matches; a LAN mirror is found and
mounted with no central config.

**Phase 6 — Private packages + revocation.** Upspin **EE packing**:
encrypt the tar, wrap the content key per authorized reader; gate reads
with Access files or blessing patterns. Vanadium **third-party caveats +
discharges**: revocation, audit, time-boxed access via a discharge
server. *Verify:* a private package installs only for an authorized
principal; revoking a discharge blocks it (negative control).

**Phase 7 — Interop. Optional.** A **VOM** codec for real Go `v.io` /
Upspin peers, and server-side TLS. Only if reaching non-Inferno peers;
Limbo↔Limbo needs neither.

## Search, in full

Search is the explicit ask, so it is spelled out as its own thread. It is
**three mechanisms on three layers**, not one feature:

1. **Browse — walk the namespace.** From phase 1: `ls /pkg`,
   `walk /pkg/net`. Discovery by navigation, pure Styx, no protocol.
   Depends on: naming layer only.
2. **Query — an index over metadata.** From phase 2's DirServer: a
   synthetic search file (the Plan 9 idiom — write a query, read results)
   backed by `registry(4)` attribute matching over each manifest's name,
   category, keywords, and `provides`. `pkg search tls`, or
   `echo 'tls client' >/pkg/search; cat /pkg/search`. Depends on: naming
   + content (metadata).
3. **Discover — find the repositories.** Vanadium advertise/scan (phase
   5): a service advertises "I serve `/pkg`" on the LAN or in the global
   mount table; clients find and mount the nearest. Because content is
   content-addressed and blessing-signed, a discovered mirror is as
   trustworthy as the origin. Depends on: naming + trust.

So the search story is: **browse comes free with naming (phase 1),
query needs the metadata index (phases 2 + 5), and cross-network
discovery needs advertise/scan (phase 5)** — each grounded in a layer the
package manager already needs.

## Critical path to a minimal searchable manager

The shortest line through the plan that yields something you can install
from *and* search:

> **Phase 1 (naming) → Phase 2 (dir/store) → Phase 4 (client, single
> signer) → Phase 5(2) (query index).**

That gives `ls /pkg`, `pkg search tls`, and `pkg install net/ssh` against
one signed repo. Phase 3 (full blessing chains) hardens trust beyond a
single signer; phases 6–7 add privacy, revocation, and Go interop. The
keystone is **Phase 1** — it is Vanadium naming, Upspin naming, and the
browse half of search, all at once, so it is the thing to build first and
share.
