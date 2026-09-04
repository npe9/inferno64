# Package management for Inferno

A design. How packages are built, named, found, trusted, fetched and
installed, done in a way that is native to Inferno's namespace model
rather than a port of apt or npm. Discovery and trust are drawn from
Upspin and Vanadium, both of which are the Plan 9 namespace idea grown
into a global, secure form, so they graft onto Styx rather than fighting
it. Nothing here is built; it is a design to pick from. Builds on the
crypto/transport arc already shipped: `tls12(2)`, `https(2)`, encrypted
Styx (`devssl` chacha20-poly1305), `ed25519(2)`, keyring sha256.

## 1. The package, and what "install" means

The central idea: **installing is a namespace operation, not a copy into
a shared tree.** Inferno's namespace is per-process and built from
`bind`/`mount`; the tree already does exactly this with `bind -a
/p9/dis /dis`. Generalise it: a package is something you mount and bind
into your namespace — per user, unprivileged, and reversible by
unbinding. No global install, no root.

**Architecture independence.** Dis is portable bytecode (`dis/sh.dis` is
just `data`); a `.dis` runs on ARM, x86, RISC-V, emu or native,
unchanged. So a package of `.dis` files is *universal* — no per-arch
build matrix the way Debian/rpm has. One artifact runs everywhere.

**Format.** A package is a tar of a small file tree — its `/dis`
modules, `/man` pages, any `/lib` data — plus a manifest. It is not
unpacked: `tarfs(4)` already serves a tar as a live Styx filesystem.
"Installing" is: verify the tar, `tarfs` it, `bind -a` its dis dir onto
`/dis`. Uninstall is unbind; upgrade is swap the bind to a new tar. The
package stays a single sealed, content-addressed blob.

**Manifest.** Reuse `proto` files — Inferno's existing description of a
file tree that makes up a distribution (`lib/proto/inferno` describes the
whole system that way). A manifest is a small proto plus a header: name,
version, content sha256, signature, and dependencies (packages, module
interfaces, and any required emu builtins/devices).

**The native-code boundary (the honest limit).** A pure-Dis package is
universal and mountable. A module needing C builtins compiled into emu
(keyring, security) or a kernel device *cannot* be namespace-installed —
emu's builtin table and `#`-devices are fixed at build time. The manifest
declares required builtins/devices; if the running emu lacks them the
install fails with a clear message, and that package's real install is an
emu rebuild. Drawing this line explicitly keeps the model honest.

## 2. Finding packages: namespace as discovery (Vanadium)

Vanadium's naming is a hierarchical mount-table system — `a/b/c` resolves
by walking mount tables that may point at remote services — and was
explicitly modelled on Plan 9 namespaces. That is Styx with the mount
table reaching across the network. So:

- **Browse = walk.** Mount a well-known package mount-table at `/pkg`.
  Now `ls /pkg/net` browses network packages, `walk /pkg/net/ssh`
  descends into versions. No special discovery protocol — `ls`/`walk`
  over Styx.
- **Search = a synthetic file.** The Plan 9 idiom: write a query, read
  results. `echo ssh >/pkg/search; cat /pkg/search`.
- **Dependencies** are global names in the manifest; the resolver walks
  the closure through the same namespace.

The transport already exists: Vanadium's secure mount tables are, in
concrete terms, authenticated + encrypted RPC exposing a namespace — i.e.
authenticated encrypted Styx, which this session built into `devssl`. So
serve `/pkg` over secured Styx; do **not** port Vanadium's RPC stack.

## 3. Content and identity: the Upspin split

Upspin gives global names for signed, content-addressed, access-controlled
files via a three-way split that maps directly onto packages:

- **KeyServer:** identity (`user@domain`) → public key + directory
  endpoint. The identity root; pairs with blessings (below) to answer
  "who published this".
- **DirServer:** name → metadata, block list, per-file wrapped keys,
  owner signature. This is the package *directory*: name → manifest →
  content-hash + signature, served as a Styx namespace.
- **StoreServer:** bytes as content-addressed blocks by hash. This is
  the package *bytes*: sha256-addressed blobs that may live on Styx,
  https, or a cloud bucket, verified by hash wherever they came from.

Separating directory from store makes mirroring/caching trivial and safe:
any source is fine because the hash proves integrity — a LAN mirror is as
trustworthy as the origin.

**Private packages, no new machinery.** Upspin encrypts each file with a
random symmetric key, wraps that key for each reader's public key, and
gates reads with `Access` files. A private package is an encrypted tar
whose content key is wrapped for each authorised reader, gated by an
Access file (or a blessing pattern, §4). Same system, public or private —
only whether the key is wrapped for the world or a named set.

## 4. Trust: blessings with caveats (Vanadium)

The answer to "can I trust what I found." A **blessing** is a certificate
chain binding a public key to a human-readable hierarchical name
(`inferno.org:net:ssh`), extended by delegation, carrying **caveats** —
embedded restrictions (expiry, method, peer). No central CA; trust flows
peer-to-peer down the chain. For a package: trust root `inferno.org`, it
blesses a `net` maintainer, who blesses the `ssh` publisher, whose
ed25519 signature covers the package. Verify the chain, not one central
signer; caveats scope and time-box it. **factotum** already holds keys
and speaks an auth protocol; blessings are a natural extension — delegable
caveated capabilities — reusable well beyond packages.

## 5. Offline / local discovery (Vanadium)

Vanadium has an advertise/scan API (mDNS/BLE). The Inferno version: a
small service advertising "I serve `/pkg`" on the LAN; a machine with no
internet mounts the nearest advertised mirror. Because content is
content-addressed and blessing-signed, trust does not degrade by fetching
from a stranger's cache — hash + blessing verify regardless of source.

## 6. Reproducibility

Because a package is an immutable, hashed blob and install is pure
namespace composition, a lockfile is a list of (name, version, sha256)
that, replayed as mounts + binds, reconstructs an exact namespace — the
Nix content-addressing property achieved naturally. A user's active set
becomes a small profile replayed at login, like `/lib/namespace`.

## 7. Publishing and organizing (the write side)

Sections 1–6 are the read side. This is how content gets *posted* and how
it is *organized* — the write side of the same Upspin/Vanadium split.

### Posting

**You publish into your own name-rooted subtree, not to a central repo.**
The steps: build (`mk`), pack the tree into a tar with a `proto`
manifest, take its sha256 — that hash *is* the content address — sign the
manifest+hash with your principal key via `factotum` (the key never
leaves the agent), and present your publisher blessing (e.g.
`inferno.org:net:ssh`) from the v23 principal store. Then publish is two
writes: the tar bytes to the content-addressed store (idempotent — the
store names them by hash, so republishing identical bytes is a no-op and
duplicates collapse), and a signed directory entry (name → manifest,
hash, signature, blessing) created in your own DirServer subtree — a
plain Styx create+write authorized by a blessing pattern. Bump a small
mutable `latest` pointer; optionally register/advertise for discovery.

**No gatekeeper.** There is no "submit to the central repository" step.
You post under your identity, into your subtree; consumers see it only
because they (or a curator they trust) mounted your subtree into a
taxonomy. Trust is the consumer's choice, via blessings — Upspin
decentralisation carried onto publishing.

### Organizing: three levels + a per-user view

1. **Storage (physical) — deliberately unorganized.** Content-addressed
   blobs in `venti`: a flat hash→bytes map, dedup'd by hash. Organization
   is a naming concern, not a storage one — the point of the dir/store
   split.
2. **Per-owner directory (Upspin).** Each publisher organizes their own
   subtree however they like.
3. **Curated taxonomy (Vanadium mount table).** The browsable
   `/pkg/<category>/<name>/<version>` view is a mount table binding owner
   subtrees onto taxonomy paths. The taxonomy is itself a signed,
   published, mountable object — the "official index" is just a
   mount-table file people choose to mount, and competing indexes can
   coexist.
4. **Per-user composed view.** Namespaces are per-process, so each user
   assembles `/pkg` by composition: mount the official taxonomy, overlay
   an org-private index, `bind -a` a local dir of in-development builds
   that shadow published ones — precedence by bind order, the
   `/p9/dis`→`/dis` pattern already in the tree. Organization is a
   composable stack of mounts, not one global hierarchy.

### Versioning

Versions are immutable, hash-named entries (`.../ssh/1.2`, `.../ssh/1.3`
never change). The only mutable things are small signed pointers
(`latest`, `stable`, channel tags) pointing at a version's hash, and they
live under each owner's subtree — no global lock. A lockfile pinning
exact hashes gives a reproducible namespace (§6).

### One metadata, two views

The manifest's category/keywords/provides/depends drive *both* the
taxonomy that organizes packages *and* the query index that searches them
(the DirServer + `registry(4)` layer). Organization and search are two
views over one metadata set — so posting a package with good metadata
makes it both well-placed and findable in one act.

## 8. Why not just port Upspin/Vanadium

Both assume a global key-server / agreed root of trust that someone runs;
decentralised-but-usable trust is the genuinely hard part, and both
projects are effectively dormant. Steal the *models*, not the code:
global content names + content-addressed store (Upspin);
namespace-as-discovery, blessings-with-caveats, advertise/scan
(Vanadium); built over Inferno's secured Styx, factotum, ed25519, sha256
— all in hand.

## 9. Staging

1. **One repo, install-by-mount.** A directory+store service serving a
   Styx `/pkg` namespace with ed25519-signed manifests and sha256
   content-addressed blobs; `ls /pkg`, verify, `tarfs`+`bind` to install.
   Close to buildable from what exists today.
2. **Blessings in factotum.** Delegable caveated trust chains, so trust
   is decentralised rather than one signer.
3. **Upspin identity + private packages.** KeyServer identity mapping;
   wrapped-key encrypted packages with Access/blessing gating.
4. **LAN discovery.** Vanadium-style advertise/scan for offline mirrors.

Each stage is independently useful; stage 1 is close to the base design.
