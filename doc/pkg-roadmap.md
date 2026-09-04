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

## Implementation milestones (what's actually built)

The phases above are the architecture; these are the shippable
increments, each verified before the next. Implementation order differs
from phase-dependency order on purpose: you cannot serve a taxonomy of
packages before a package exists, so the local format + install come
first, before the Phase 1 naming service.

**M1 — Local format + install-by-mount. DONE.** `pkg(1)`
(`appl/cmd/pkg.b`, `man/1/pkg`): `pack`, `info`, `install`, `list`,
`remove`. A package is a tar of `pkg/manifest` (ndb attribute lines, so
`registry(4)` can index it later) + `dis/`/`man/`/`lib/`. Install mounts
the tar with `tarfs(4)` at `/mnt/pkg/<sha256>` and binds its `dis/` after
`/dis`; commands then resolve by bare name. `list`/`remove` read the real
mount state, not a side file. Verified end to end by `tests/pkglocal.sh`:
a command is unresolvable before install, runs after install, and is
unresolvable again after remove — both negative controls proving install
and remove actually compose/decompose the namespace. The load-bearing
assumption (a `bind` done by a command persists in the invoking shell's
namespace) was confirmed empirically first.

**M2 — Signing + verification. DONE.** `pkg genkey`/`sign`/`verify` and
a `-k` option on `install`. A package carries a detached `pkg.tar.sig`: a
`keyring(2)` certificate over the archive's hash plus the signer's public
key — the same key/cert types `v23-security(2)` principals use, so M5's
blessing chains compose. `install` verifies a present signature, rejects
a package whose signer does not match `-k`, and warns on unsigned.
Verified by `tests/pkgsign.sh` with both negative controls: a wrong
pinned key is rejected and a tampered archive fails verification.

**M3 — Repository + install by name. DONE (local form).** `pkg publish
repo pkg.tar` files a package into `repo/<name>/<version>.tar` (+ `.sig`),
and `pkg install <name>` resolves a repository name (under `-r`,
`$PKGPATH`, or `/pkg`) to its newest version, verifies it, and installs -
name resolution IS a name-space walk of the repository. So a repository
served over Styx and bound at `/pkg` is browsable by `ls` and installable
by name with no new client code. Verified by `tests/pkgrepo.sh`
(two versions published, newest resolved and verified; a missing name
fails). Still ahead for the full keystone: the Styx file server itself
(a synthetic tree + a search file, M4) and factoring the manifest parse
into `appl/lib/pkg.b` when the server needs it.

**M4 — Search. DONE (direct form).** `pkg search [-r repo] term...` walks
the repository, reads each package's newest manifest, and prints the
packages matching all terms (case-insensitive over name, category,
keywords, provides, description), best first; no term lists all. So
search and the repository taxonomy are two views of one manifest metadata
set. Verified by `tests/pkgsearch.sh`: a keyword matches the right
packages and only those, multiple terms AND, an impossible term matches
nothing, a bare search lists all. Still ahead: backing this with a
precomputed `registry(4)` index and exposing it as a synthetic
`/pkg/search` file once the Styx naming server (M3's server half) exists.

**M5 — Trust (blessings).** Verify a publisher `v23` blessing chain
against trusted roots in `factotum`.

**M6 — Remote fetch.** Content-addressed blobs over `https(2)`/secured
Styx; mirrors, verified by hash.

**M7 — Publish.** `pkg publish` writes a signed entry + blob into the
publisher's own DirServer subtree (the write side, `doc/package-
management.md` §7).

## The Upspin content namespace (chosen foundation)

The `pkg(1)` milestones above proved install-by-mount, but the more
principled direction — and the one being taken — is Upspin's: content is
not a monolithic tar but content-addressed blocks; a name is an
owner-rooted global `user@domain/path`; and a name maps to a *signed*
directory entry verified through a KeyServer, not through any key the
entry carries. Built as its own module (`module/upspin.m`,
`appl/lib/upspin.b`, `appl/cmd/upspin.b`, `man/1/upspin`, `man/2/upspin`),
independent of `pkg`:

- **Store** — content-addressed blocks. `get` rehashes every block and
  rejects a mismatch, so content-addressing is enforced by the check, not
  the file name. Fixed 1 MiB blocks; identical content dedups.
- **DirEntry + Dir** — a name maps to a signed entry listing its block
  refs. One canonical serializer (`signedbytes`) is used by both sign and
  verify and covers the name and the ordered block list, so neither can
  change under a valid signature. Names are sanitized so a path cannot
  escape the owner's subtree.
- **KeyServer** — `user@domain → public key`. Verification derives the
  owner from the name, looks up that owner's key, and checks the
  signature — the architectural upgrade over a single pinned key.

Verified end to end by `tests/upspinlocal.sh` with three negative
controls, each a distinct guarantee: a forged entry stored under another
owner's name is rejected (KeyServer binding), a tampered signed field
fails the signature (canonical serializer covers it), and a corrupted
store block fails its content hash (Store.get rehashes). `upspin put`/
`get`/`ls` round-trip.

Two hashes, two jobs: block refs are SHA-256 (content addressing); the
entry signature digest is SHA-1 (the keyring certificate algorithm).

Next on this foundation: end-to-end encryption (per-reader wrapped content
keys + Access files, reusing the AES-GCM/ECDH primitives already in
`keyring`), serving Store/Dir/KeyServer over `styx(2)` so names resolve
across the network and mount at `/pkg`, verification through `v23`
blessing chains instead of a flat KeyServer, and finally re-expressing a
package as an Upspin subtree so `install` becomes get-by-name over this
namespace — retiring `pkg`'s bespoke tar+repo format.

## Organizing the namespace at scale

An owner-rooted namespace has no central "everything" directory to
organize; you organize within each owner's tree and keep track of the
*owners* through a registry. These are the techniques big multi-user
systems (SDF and every large UNIX site, git, Venti, DNS/email) use, mapped
onto our Store/Dir/KeyServer.

- **The KeyServer is the roster of principals — our `/etc/passwd`.**
  It is the authoritative "who exists," mapping `user@domain` to a key
  (and, in full Upspin, to where that user's DirServer lives). Organizing
  the system is mostly organizing this registry and each owner's tree, not
  inventing a global hierarchy.
- **Within an owner's tree: convention, not enforcement.** Like UNIX
  `~/public_html`/`~/Maildir`, grow well-known subtrees —
  `owner/pkg/...` (packages), `owner/pub/...` (public), an `Access` file
  per level (per-directory ACL). Each owner curates their own tree; the
  system imposes no schema.
- **Shard so no directory explodes.** A flat `store/<64hex>` of millions
  of blocks dies; shard by hash prefix `store/ab/cdef...` (git objects,
  Venti arenas, S3 prefixes, and SDF's own `/udd/<letter>/<user>` home
  splitting). Shard the registry as `keys/<domain>/<user>`.
- **Indexes are derived and rebuildable, off the trust path.** Search /
  member-map / `finger`-style lookups are built from the signed entries
  and blocks and can be regenerated; verification always checks the
  signature and the block hash, never the index — so a bad index can only
  fail to find, never cause acceptance of bad content.
- **Federate by domain.** `user@domain` delegates like email/DNS: each
  domain runs its own Store/Dir/KeyServer; the registry (or DNS) says
  which. The system scales by keeping track of domains, each of which
  keeps track of its own users — not by one giant server.
- **A system owner publishes curated views.** A well-known principal
  (e.g. `registry@domain`) publishes the package taxonomy, a member
  directory, featured lists — as ordinary *signed* subtrees anyone can
  mount, several curators coexisting. Organization by publication, not by
  central schema.
- **Per-owner quotas + block GC.** A content-addressed Store needs
  reference counting / garbage collection to reclaim unreferenced blocks
  (Venti's problem) and per-owner quotas/accounting (SDF's disk quotas).
- **Inferno twist: per-process namespaces.** The organization a user
  *sees* is a view they compose by binding the owner subtrees and curated
  indexes they care about into their own namespace (the `bind /p9/dis
  /dis` pattern) — federated, sharded, derivably indexed, and composable,
  never one monolithic administered tree.

Concretely for the next increments: shard `Store` by hash prefix; make
`KeyServer` a `keys/<domain>/<user>` registry that also records each
user's DirServer endpoint (federation-ready); keep `Dir` owner-rooted with
conventional `pkg`/`pub`/`Access` subtrees; designate a system owner for
curated indexes; treat all search indexes as derived.
