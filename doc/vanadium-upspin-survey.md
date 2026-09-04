# Survey: what it takes to bring Vanadium and Upspin into Inferno

An inventory of the components each system needs, marked against what
this tree already has. The short version: **Vanadium's security+RPC core
is already ported, built, and passing its selftest** — but its source is
missing from the tree — and **every cryptographic primitive Upspin needs
already exists**, so Upspin is unstarted but not far off. Naming and
discovery are the real remaining design work for both.

## The surprise: a Vanadium port already exists here

`module/v23.m` is an Inferno-native port of Vanadium core
(`v.io`/`github.com/vanadium/core`). It defines:

- **V23security** — `Principal` (keyring Elgamal keypair), `Blessings`
  (chains of `Certificate`), `Caveat`, `blessself`/`bless`/`sign`,
  blessing patterns, roots, and `authorize` (ACL by blessing pattern).
- **V23rpc** — `serve`/`serveconn`/`dial`/`call`: framed RPC over
  `dial(2)` with a blessing exchange at connect time, framed on
  `msgio(2)`.

Built libraries `dis/lib/v23/{security.dis,rpc.dis}` and commands
`dis/v23/{principal,fortune,fortuned,selftest}.dis` are present (the
classic Vanadium "fortune" client/server demo), with nine man pages
(`v23-0intro`, `v23-security`, `v23-rpc`, `v23-principal`, `v23-fortune`,
`v23fortune`, `v23-selftest`, `v23-fortuned`, `v23(6)` wire framing).
`/dis/v23/selftest.dis` **runs and prints `v23 selftest: ok`** —
principal creation, self-blessing, delegated blessing, encode/decode,
pattern matching, expiry caveats, ACL checks all pass.

**The source was missing, now recovered.** Originally `appl/cmd/v23/`
and `appl/lib/v23/` did not exist here; only `module/v23.m`, the man
pages, and the demo scripts were tracked, and the `.dis` were orphaned
build artifacts (the tree does not track `.dis`). The `.b` source turned
out to be *untracked* working-tree files in the sibling
`inferno-vanadium` worktree — never committed anywhere. It has now been
pulled in and wired into the build (`appl/lib/v23`, `appl/cmd/v23`,
`appl/wm/v23fortune.b`, `doc/v23.md`; `v23` added to the `appl/lib` and
`appl/cmd` DIRS and to `appl/wm`'s mkfile). Verified by negative control:
the orphaned `.dis` were deleted and rebuilt from the recovered source at
identical sizes, and the freshly-built selftest still prints `v23
selftest: ok`. The port is now rebuildable and extensible. No Upspin
source exists in either worktree.

## The substrate already in the tree

Both systems are, at heart, secure global namespaces with cryptographic
identity at the leaves. The pieces that provides:

**Crypto (essentially complete).** `keyring(2)`: sha256/sha512,
hmac_sha256, AES-GCM (`aesgcm_*`), ChaCha20-Poly1305 (`ccpoly_*`),
poly1305, RSA (sign/verify/gen), DSA, IPint bignum, Diffie-Hellman
(`dhparams`), and ECDH — both curve25519 (`curve25519_dh_*`) and P-256
(`p256.b`). `ed25519(2)` (verify; sign is a known gap). `x509(2)` +
`asn1(2)`: DER certificate **parse, encode, and sign** (`Signed.sign`/
`.encode`, `verify_certchain`/`verify_certpath`/`verify_chain_host`) —
so certificate-chain *issuance*, not just validation, exists.

**Content-addressed store (present and built).** `venti(2)`
(`module/venti.m`) with `vacfs`/`vacget`/`vacput` (source + `.dis`
present) is a working Venti client — Plan 9's content-addressed block
store, `Score`-addressed blocks (`Scoresize=20`, i.e. SHA-1), with the
`vac` Root/Entry archive format. This is Upspin's StoreServer, already
here — modulo hash choice (SHA-1 vs Upspin's SHA-256).

**Naming / resolution.** `registry(4)` (`ndb/registry`) — a 9P file
server for dynamic registration and attribute-based location of services
that come and go, mountable locally or served over a connection. Plus
`cs` (connection server), `dns`, `ndb`. This is the native analog of
Vanadium's mount table / Namespace.

**Secure transport.** `tls12(2)` + `https(2)` (verifying TLS 1.2 client),
and the encrypted-Styx record layer (`devssl` chacha20-poly1305) with a
server side via `9export(1)`. `v23-rpc` does not use TLS — it runs its
own blessing handshake over `dial(2)`/`msgio(2)`.

**Encoding.** `asn1`, `json`, `xml`. No protobuf and no VOM.

## Vanadium (v23): done vs missing

| Component | State |
|---|---|
| Principals, keypairs | **Done** (built) |
| Blessings (cert chains) | **Done** |
| Caveats | **Partial** — only `const` + `expiry`; no method, peer-blessing, or third-party (discharge-based) caveats, though `PurposeDischarge` is reserved |
| Blessing patterns + ACL `authorize` | **Done** |
| Blessing-authenticated RPC | **Done** (framed over `msgio`, Inferno-native, **not** Go VOM) |
| **Source code** | **Missing — recover it** |
| Naming / mount table (global Namespace) | **Missing** — `registry(4)` + Styx mount is the native substrate to build on |
| Discovery (advertise/scan, mDNS/BLE) | **Missing** — `registry` attribute lookup is a partial analog |
| VOM codec (Go `v.io` interop) | **Missing** (deliberate; text framing instead) |

So Vanadium's *authorization* model is essentially in hand; its *naming*
and *discovery* halves are not, and completing them is the interesting
work (and exactly what package discovery needs).

## Upspin: done vs missing

Nothing Upspin-specific is written, but the substrate is unusually
complete:

| Component | State |
|---|---|
| Content-addressed StoreServer | **Have** via `venti` (SHA-1 scores; want SHA-256 for parity — small change or a thin new CAS) |
| EE packing primitives (AES, ECDH key-wrap, sign, hash) | **Have all** (AES-GCM, curve25519/P-256 ECDH, ed25519/RSA sign, sha256) |
| EE packing *logic* (random file key, wrap per reader, sign entry) | **Missing** — compose the above; medium |
| Access control (readers/writers) | **Have an engine** — reuse v23 blessing patterns + `authorize`, or Upspin `Access` files |
| Signed directory entries | **Have machinery** — `x509 Signed` or v23 certs |
| Global naming `user@domain/path` | **Missing** — layer on `registry`/`cs` |
| KeyServer (user → pubkey + dir endpoint) | **Missing** — a signed key mapping; `secstore`/`factotum` hold keys locally |
| DirServer (name → metadata, blocks, wrapped keys, sig) | **Missing** — a Styx service over venti Root/Entry blocks |

So Upspin is a matter of writing the naming, KeyServer, DirServer and the
EE packing loop — no new cryptography, and the store already exists.

## Cross-cutting gaps

- **Server-side TLS is absent** — `tls12`/`https` are client-only. Not
  necessarily blocking: `v23-rpc` authenticates with its own blessing
  handshake, and encrypted Styx already has a server side. Only a
  TLS-fronted Upspin/Vanadium *server* would need it.
- **No VOM/protobuf** — only needed for interop with real Go `v.io` or
  Upspin peers. Limbo↔Limbo needs none.
- **ed25519 signing** — verify exists, sign does not; principals use
  keyring Elgamal today, so this only matters if ed25519 principals or
  ed25519 client keys are wanted.
- **Venti SHA-1** — fine for storage dedup, weak as a security hash; use
  SHA-256 scores if content hashes are part of the trust story.

## Effort and order

1. **Recover the v23 source** — **done.** Pulled from the
   `inferno-vanadium` worktree and wired into the build; rebuilds from
   source and passes selftest (negative-control verified). The port is
   now maintainable.
2. **Vanadium naming** — wire `registry(4)` + secured Styx as the mount
   table so a global `/pkg`-style namespace resolves and can be walked.
   Medium; this is the piece package discovery needs.
3. **Upspin store parity** — SHA-256 venti scores or a thin CAS. Small.
4. **Upspin EE packing** — compose existing primitives into
   pack/unpack + per-reader key wrap. Medium; no new crypto.
5. **KeyServer + DirServer** as Styx services over venti. Medium.
6. **As needed:** richer caveats + third-party discharges, Vanadium
   discovery (advertise/scan), a VOM codec for Go interop, server-side
   TLS, ed25519 signing.

The through-line: the cryptography and the content store are done, a
working blessings/RPC layer already exists (source recovery aside), and
the genuine remaining work for both systems is *naming and discovery* —
which is the same gap the package manager needs filled, so it is worth
doing once, over `registry(4)` and secured Styx, and sharing.
