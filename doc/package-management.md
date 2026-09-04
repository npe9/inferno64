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

## 7. Why not just port Upspin/Vanadium

Both assume a global key-server / agreed root of trust that someone runs;
decentralised-but-usable trust is the genuinely hard part, and both
projects are effectively dormant. Steal the *models*, not the code:
global content names + content-addressed store (Upspin);
namespace-as-discovery, blessings-with-caveats, advertise/scan
(Vanadium); built over Inferno's secured Styx, factotum, ed25519, sha256
— all in hand.

## 8. Staging

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
