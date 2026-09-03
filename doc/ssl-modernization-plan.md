# SSL/TLS modernization plan

## Status (most recent first)

**ECDSA/P-256 DONE, 2026-09-03 — the TLS layer now reaches ECDSA
hosts, and live DNS resolution works.** The gap named below is
closed. New `p256(2)` (`appl/lib/crypt/p256.b`) implements NIST P-256
in pure Limbo on `keyring`'s IPint — ECDSA verify and ECDH — verified
by `p256test(1)` against Python `cryptography` vectors (valid sig
verifies; corrupted sig and wrong hash rejected; ECDH known-answer
matches; off-curve points rejected; fresh-keypair round trip agrees).
Wired in two places: `x509(2)` verifies `ecdsa-with-SHA256/384/512`
certificate signatures (added id-ecPublicKey / secp256r1 / the ecdsa
sig-alg OIDs, and an `ecdsa_checksig` that pulls the EC point from the
issuer's SubjectPublicKeyInfo and the (r,s) from the DER signature);
`tls12(2)` now offers all four ECDHE-{RSA,ECDSA}-{AES128-GCM,ChaCha20}
suites and both X25519 + secp256r1 groups, does P-256 ECDHE when the
server names secp256r1, and verifies the ECDSA ServerKeyExchange
signature. Measured: dns.google, cloudflare-dns.com and dns.quad9.net
all complete TLS 1.2 + ECDHE-ECDSA-AES128-GCM over P-256 — and
`doh(2)`/`dns(1)` now resolve real names live (`dns github.com` →
140.82.113.3; `one.one.one.one` → 1.1.1.1). All the RSA-path tests
(tls12test/httpstest/s3test/bskytest/mastotest) still pass unchanged.
End-to-end negative control: corrupting a P-256 curve constant breaks
both p256test and the live DoH handshake (ServerKeyExchange verify
fails), then restored. **Also found+fixed a real IPint gotcha**: this
keyring's `and`/`shr` builtins emit debug noise / misbehave, so P-256
reads scalar bits from `iptobebytes()` rather than through IPint's bit
operators.

Still not done (smaller, tracked): DoH is not yet wired into
`/net/cs`, so a program must call `dns(1)`/`doh(2)` explicitly rather
than dialling a name; no TLS 1.3; no revocation checking. P-256 is
affine (not constant-time) — fine for verifying public signatures and
ephemeral ECDH, the only uses here.

**Follow-on, 2026-09-03 — the ECDSA/P-256 gap, found by building on
top of the finished stack.** Two clients were built past step 9 to
exercise the transport against more of the real world: `awsv4(2)`/
`s3(1)` (AWS SigV4, works — S3 takes the X25519+ECDHE-RSA scope) and
`doh(2)`/`dns(1)` (DNS-over-HTTPS, to close the `/net/cs` name gap).
DoH's wire format is complete and offline-verified (`dohtest(1)`), and
`https(2)` gained `requestto()` (dial a pinned IP, verify the real
hostname's cert) precisely so DNS can bootstrap. But **live DoH is
blocked at the TLS layer**: every current public DoH resolver
(dns.google, Cloudflare, Quad9) presents an **ECDSA (secp256r1)**
certificate, and several want **P-256 ECDHE**; `tls12(2)` verifies
**RSA chains over X25519 only**. Measured directly: dns.google returns
its real `dns.google` cert only to a client offering ECDHE-ECDSA over
P-256; an RSA client gets a fallback `*.google.com` cert that does not
name it (correctly rejected). So the next real transport step is
**ECDSA signature verification + P-256** (EC point arithmetic over
secp256r1 — 9front's `libsec/port/ecc.c` is the port source, matching
this tree's translate-real-C practice), which would light up DoH live,
Cloudflare-fronted hosts, AWS STS, and the growing ECDSA-only slice of
the web, all unchanged above it. Sizable and security-critical (a
verify bug is a silent MITM), so flagged rather than rushed.

**Real general x509 bug fixed en route (2026-09-03):** ASN.1
**UTF8String (tag 12)** — the *default* DirectoryString type in modern
certificates (RFC 5280) — was entirely absent from `module/asn1.m`/
`appl/lib/asn1.b`, so any certificate whose subject/issuer used it was
unparseable (`can't parse subject`). It went unnoticed because the
first real chains tested (Amazon, Let's Encrypt/ISRG) happen to use
PrintableString; Google's chain uses UTF8String and surfaced it.
Added to the decoder, `is_string`, and `tostring`; all existing
cert-verifying tests (tls12test/httpstest/s3test) still pass. This is
independent of DoH and fixes cert parsing tree-wide.

**Step 9 done, 2026-09-02 — THE PLAN'S ACCEPTANCE CRITERION IS MET.**
`bsky(1)` and `masto(1)` now speak HTTPS through this tree's own
stack and the `#C`/curl stopgap is deleted from both. The layer in
between is new: `https(2)` (`module/https.m` +
`appl/lib/https.b`), one HTTP/1.1 request per TLS session over
`tls12(2)`, reading the response strictly by its own framing
(Content-Length / chunked / read-to-close), treating HTTP error
statuses as results (APIs put diagnostics in 4xx bodies — this is
what lets the clients' existing JSON error decoding keep working
unchanged), no redirects. Name resolution: dial by name first (real
when `ndb/cs` serves `/net/cs`), falling back to hosted emu's
built-in `$Srv` resolver (`Srv->iph2a`, the existing mechanism —
found, not built) — so hostname URLs work in this emu instance
despite the still-open `/net/cs` gap, and `#C` is nowhere involved.
`CLAUDE.md`'s rule paragraph updated from "still in violation" to
describing the shipped state.

Evidence: `httpstest(1)` (9 checks, live + offline): both public
endpoints by hostname; HTTP-error-as-result; resolution failure;
chunked decoding via a test seam (live hosts all send Content-Length
now) including truncation and garbage-size rejection; and an
end-to-end wrong-certificate refusal (a literal-IP https URL — no
public cert names a bare IP). The chunked positive case was
negative-controlled the hard way: corrupting the decoder's size
arithmetic (*16→*15) initially PASSED because every test chunk had a
single-digit size and "1A" routes its second digit through the
hex-letter arm — the test was strengthened (a "10"=16-byte chunk)
until the corruption visibly failed, then the corruption removed.
`bskytest(1)` and `mastotest(1)` PASS unchanged over the new
transport (including bsky's real-POST bogus-login leg, which gets a
real decoded `AuthenticationRequired` from bsky.social through our
TLS). Migration control: hiding `lib/tls/ca-bundle.pem` makes both
client test suites fail with the trust-root error, restore makes
them pass — the clients demonstrably ride the verifying stack.

Left open, tracked, deliberate: `/net/cs` still unserved (the `$Srv`
fallback covers hosted mode; running `ndb/cs` is the native-mode
answer); no revocation checking (tls12(2) BUGS); `ssl3.m`/`ssl3.b`
left as-is (nothing migrated off it here — it predates this plan).

**Step 8 done, 2026-09-02 — certificate chain verification, live on
every handshake.** `tls12->client()` now authenticates the server
before deriving any secret: `x509(2)`'s new `verify_chain_host()`
(leaf-first wire chain → trusted out-of-chain root; issuer/subject
chaining, validity dates, intermediates' CA bit, subjectAltName
dNSName matching with single-label wildcards and no CN fallback, and
every RSA signature actually verified), plus a check of the
ServerKeyExchange signature against the leaf's key over both hello
randoms. **The trust-root decision**: a frozen copy of Mozilla's CA
bundle ships in the tree at `lib/tls/ca-bundle.pem` (121 roots, the
"like a real OS distribution" option; refresh from
https://curl.se/ca/cacert.pem — a stale bundle fails safe, missing
new roots rather than trusting anything extra). Supporting work:
`pkcs(2)` gained sha1/256/384/512WithRSAEncryption ids and a strict
EMSA-PKCS1-v1_5 verify that reconstructs and compares the ENTIRE
padded block (the old scan-for-separator path invites low-exponent
forgeries); `tls12(2)` gained `loadroots()`/`CAPATH`.

**Three latent, never-worked x509.b bugs found by the first real
chain** (all SSLv3-era code that had never met a modern certificate):
(1) `parse_gname` treated GeneralName's dNSName/rfc822Name/URI as
EXPLICITLY tagged and tried to DER-decode the string bytes — no real
subjectAltName ever parsed; (2) `decode_basicConstraints` demanded
both optional fields (real leaves omit both, real roots omit pathlen)
and didn't surface the CA boolean at all — `ExtClass.BasicConstraints`
now carries `isca`; (3) DER's BOOLEAN TRUE is 16rFF but every
criticality check compared `!= 1`, so any critical extension (i.e.
every real basicConstraints) failed `ExtClass.decode`. Each was found
as a live handshake failure, fixed, and re-run — the accidental
negative controls proving `client()` really aborts when verification
fails.

`tls12test(1)` grew four verifier controls using the chain a real
session produced: wrong hostname refused; root set without the
anchor refused; truncated chain refused; undoctored chain still
verifies (8 checks total, 3/3 consecutive clean runs). Hand-run and
restored: one flipped bit in the ServerKeyExchange signed data made
every handshake fail the signature check; one corrupted byte in
pkcs.b's SHA-256 DigestInfo prefix made every handshake fail chain
verification — the RSA arithmetic itself is load-bearing, not just
the structure checks. All five sibling crypto tests
(tls12prftest/hmacsha256test/x25519test/aesgcmtest/ccpolytest) still
pass. Both hosts' chains re-measured this session: all
sha256WithRSAEncryption, RSA-2048/4096 — the supported-algorithm set
matches reality.

**Still open**: no revocation (CRL/OCSP), no name constraints —
documented in tls12(2) BUGS as accepted scope, not silent gaps. The
`/net/cs` hostname-resolution gap still stands. **Remaining: step 9 —
migrate `bsky(1)`/`masto(1)` off `#C`**, now unblocked.

**Step 7 done, 2026-09-02 — the full handshake and record layer work
end to end against both real target hosts.** `tls12(2)`
(`module/tls12.m` + `appl/lib/crypt/tls12.b`, which until now held only
the PRF) is now a real TLS 1.2 client: `client(fd, hostname, suites)`
runs ClientHello through both Finished messages (ECDHE over X25519,
transcript hash, master secret, key expansion, ChangeCipherSpec,
verify-data both directions) and returns a `Session` with
`read`/`write`/`close` doing real AEAD record protection. The
handshake/derivation flow is ported from 9front's `tlshand.c` and the
record construction (tlsPackAAD's 13-byte AAD, GCM's salt+explicit
nonce with the random-XOR-sequence explicit part, ChaCha's IV-XOR-
sequence nonce, the RFC 6.3 key-block split) from `devtls.c` — 9front
keeps that half in its kernel; here both halves are Limbo. The step-4
probe `tlshellotest(1)` was deleted and its ClientHello encoding
absorbed, exactly as its own man page promised.

`tls12test(1)`, all live, passing 3/3 consecutive runs on 2026-09-02:
AES-128-GCM leg against `bsky.social` (real HTTPS GET, decrypted
`HTTP/1.` response back); ChaCha20-Poly1305 leg against
`mastodon.social` (which had to be offered ChaCha *only* — it prefers
GCM given both, re-measured live same day); plus two in-test negative
controls (corrupting `rseq` makes the next read fail record
authentication; corrupting `wseq` makes the server kill the
connection instead of answering). Two more negative controls were run
by hand against the library and restored: one flipped bit in the
client Finished verify data → every server refuses (mastodon with
fatal alert 51, `decrypt_error` — the exact RFC-assigned alert); one
flipped bit in the expected server Finished → the client itself
rejects with a verify-data mismatch. So both directions of Finished
verification are demonstrably load-bearing, not decorative.

Gotcha for future sessions: the *installed* `emu-g` binary predated
the new keyring builtins (link typecheck error naming
`$Keyring->aesgcm_decrypt()` at module load) — `mk CONF=emu-g install`
in `emu/MacOSX` first. Also, any `.b` file including `tls12.m` must
include `keyring.m` before it now (the `Session` adt embeds keyring
state refs); `tls12prftest.b` needed that one-line fix.

**What remains before `bsky(1)`/`masto(1)` can migrate off `#C`
(steps 8–9): certificate chain verification** — still completely
open, still the gap that makes every session encrypted but
UNAUTHENTICATED (both `tls12(2)` and `tls12test(1)` say so in
BUGS) — including the trust-root decision, plus the migration
itself. The `/net/cs` name-resolution gap also still stands (clients
dial literal IPs).

**Earlier status.** Primitive 6 (ChaCha20-Poly1305) landed, completing
both record-protection AEADs this plan's measured scope needs. Primitive
5 (AES-GCM) is landed. Step 4 (real ClientHello/ServerHello round trip)
is done — see below. Primitives 1–3 are landed and verified:

- `hmac_sha256` (`libsec/hmac.c` + `keyring.m`/`.c`) — `hmacsha256test(1)`,
  4 vectors (RFC 4231 case 1 + 3 from the host's own `openssl(1)`).
- TLS 1.2 PRF (`module/tls12.m` + `appl/lib/crypt/tls12.b`) —
  `tls12prftest(1)`, 4 vectors from a from-scratch reimplementation of
  RFC 5246 §5, cross-checked against the host's own `openssl kdf TLS1-PRF`
  (a second, genuinely independent implementation — the RFC has no
  published vectors of its own).
- X25519 (`libsec/curve25519.c`+`curve25519_dh.c`+`tsmemcmp.c`, ported from
  9front's curve25519-donna derived implementation; `keyring.m`/`.c`) —
  `x25519test(1)`, 5 cases against vectors from Python's own `cryptography`
  library (a real, independent X25519 implementation) plus a property check
  of the real key-generation API. Caught its own near-miss: a from-memory
  attempt at RFC 7748's own published vectors turned out corrupted (odd
  hex-digit count), so the vectors here come from running a real library
  instead of recalling a spec.

All three negative-controlled. Next up per the revised staging order below:
just enough of the handshake state machine to get a real ClientHello/
ServerHello round trip against `bsky.social`, *before* AES-GCM/ChaCha20-
Poly1305 (record protection only matters after the handshake completes).
`bsky(1)`/`masto(1)` still drive host `curl(1)` through `#C` — see
`CLAUDE.md`'s own rule, which this plan exists to satisfy.

**Prerequisite checked before writing any TLS code, 2026-09-02**: whether
this emu instance can dial a real TCP connection at all —
`module/dial.m` had been read this session, never run. `dialtest(1)`
found a real, separate gap: dialing by hostname
(`dial->dial("tcp!bsky.social!80", nil)`) fails with `invalid IP address`
(from `emu/port/devip.c`, not a Limbo bug) — `/net/cs`, the connection
server, is not resolving names in this emu instance. Dialing the same
host by a literal IP (looked up once outside emu) works cleanly: a real
TCP connect, a real HTTP/1.0 request written, a real response read back.
**The transport itself is proven; DNS/cs resolution is a separate,
still-open gap**, tracked here, not solved. The handshake work below can
proceed by dialing literal IPs (SNI still needs the real hostname string,
which is available regardless of whether the name resolves); fixing `cs`
is its own task if `bsky(1)`/`masto(1)` are to keep taking hostnames from
users.

Also captured, same session: a real byte-level TLS 1.2 handshake against
`bsky.social` (`openssl s_client -tls1_2 -msg -state`), saved at
`doc/fixtures/bsky-tls12-handshake.txt` — the full ClientHello through
both sides' Finished messages, in hex, annotated. This is the diff
reference for the ported ClientHello encoder (build ours, confirm it
matches modulo random/session-id/extension-ordering) and the fixture for
the ServerHello/Certificate/ServerKeyExchange parser — parseable offline,
no network needed, the same shape as `feedtest`'s captured-response
approach.

**Step 4 done, 2026-09-02**: `tlshellotest(1)` (disposable probe, per the
revised staging above) hand-rolled a minimal TLS 1.2 ClientHello — SNI,
X25519-only `supported_groups`, `ec_point_formats`, `signature_algorithms`,
offering exactly the two cipher suites this plan measured — built from
9front's own `tlsClientExtensions()`/`makeciphers()` field layout, cross-
checked byte-by-byte against `doc/fixtures/bsky-tls12-handshake.txt`
before ever sending it. **Worked on the first live attempt** against a
real `bsky.social` IP: the server answered with `ServerHello` naming
cipher `0xc02f` (`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, exactly the
suite this plan measured), a 3-certificate `Certificate` message (read,
**not verified** — chain verification is still the open gap below), and
`ServerKeyExchange` naming curve X25519 with a 32-byte public key,
followed by `ServerHelloDone`. Both the offline round-trip self-check and
the live cipher/curve confirmation were negative-controlled (corrupt the
encoder/comparison, confirm FAIL with the real values shown, restore,
reconfirm PASS). **This closes the "does the front half of a real
handshake actually work" question** — the milestone this staging step
existed to answer. No key derivation, `ClientKeyExchange`, `Finished`, or
record decryption was attempted, per the step's own explicit stopping
point.

**Primitive 5 (AES-GCM) done, 2026-09-02**: `libsec/aes_gcm.c`, ported
from 9front's `libsec/port/aes_gcm.c`, exposed via `module/keyring.m`'s
new `aesgcmsetup`/`aesgcm_setiv`/`aesgcm_encrypt`/`aesgcm_decrypt` (same
opaque-ADT-plus-native-struct convention as the existing `AESstate`/
`aescbc`). One deliberate departure from the source, not a rewrite: the
16×256×4-word (64KB) precomputed GHASH table is dropped in favour of that
same source's own table-free `gfmul()` path — already present in the
code being ported, normally disabled behind `if(0)`, made live here
instead. Correctness-identical, slower per block, no need for the table
given this client's actual load (a handful of TLS records, not a busy
server). `aesgcmtest(1)`: 6/6 real cases, vectors cross-checked between
two independent implementations (Python's `cryptography` and
`pycryptodome`, agreeing byte-for-byte before being trusted) covering
empty AAD, non-empty AAD, a partial-final-block plaintext both with and
without AAD, a non-96-bit IV (the GHASH-based `aesgcm_setiv` path, not
just the fast 96-bit path), and tag-corruption rejection. Two negative
controls confirmed: corrupting the GHASH reduction constant breaks 4/6
cases with real-vs-wrong bytes shown; disabling the `tsmemcmp` check
inside `aesgcm_decrypt` makes exactly the tag-rejection case fail (5/6),
leaving the genuinely-valid-tag cases unaffected as expected. Both
restored and reconfirmed 6/6.

Real gotcha hit: `include/libsec.h`'s new `AESGCMstate` struct originally
named its GHASH-subkey field `H`, which collided with `libinterp/
interp.h`'s own `#define H ((void*)(-1))` (the interpreter's nil-heap
pointer sentinel, used pervasively as `f->ptr == H` in glue code) once
`libsec.h` got included into `keyring.c` — a real, if narrow, single-
letter naming collision between an unrelated native library header and
an interpreter-internal macro. Renamed to `ghashH`; not caught until the
actual `cc` build (clang's isolated per-file lint never flagged it, since
it doesn't see `interp.h`'s macro from `libsec.h`'s point of view) — a
reminder that this tree's clang-based inline diagnostics are not a
substitute for the real `mk`-driven build when editing headers that get
included alongside `interp.h`.

**Primitive 6 (ChaCha20-Poly1305) done, 2026-09-02**: `libsec/poly1305.c`
+ `libsec/ccpoly.c`, ported from 9front's `poly1305.c`/`ccpoly.c`. Raw
ChaCha20 (`libsec/chacha.c`/`chachablock.c`) predates this plan and is
untouched — only Poly1305 and the AEAD wrapper were new. Exposed via
`keyring.m`'s `ccpolysetup`/`ccpoly_setiv`/`ccpoly_encrypt`/
`ccpoly_decrypt`, same convention as AES-GCM. One deliberate departure
from the source: Poly1305 gets its own small `Poly1305state` rather than
reusing the shared `DigestState` (`state[5]` is too small for Poly1305's
14 words, and `sha1pickle.c`/`md5pickle.c` already depend on
`DigestState`'s exact size — growing it was judged a bigger, riskier
change than this primitive needed). `ccpolytest(1)`: 5/5, including RFC
8439 §2.8.2's own published worked example (not just a from-scratch
reimplementation of the spec) plus three vectors cross-checked between
Python's `cryptography` and `pycryptodome`. Negative control: corrupting
Poly1305's `r[0]` clamp mask broke the RFC vector's tag with the real
wrong bytes shown (the other three cases, using fresh random keys, only
had ~50% odds of the single corrupted bit mattering for their particular
key material and happened not to show it — the RFC vector's failure
alone is sufficient real evidence; not a flaw in the test, just a
narrower mutation than ideal). Restored, reconfirmed 5/5.

This closes out both record-protection AEADs (`TLS_ECDHE_RSA_WITH_
AES_128_GCM_SHA256` and `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305`) the
measured scope needs — primitives 1-3, 5, and 6 are done; only the
handshake state machine itself (step 4's ClientHello/ServerHello slice
is done, the rest — Finished messages, real record encryption/
decryption end to end — remains) and certificate chain verification are
outstanding before `bsky(1)`/`masto(1)` can migrate off `#C`.

**Post-commit review caught a real, shipped bug in `ccpoly_setiv`**:
`Keyring_ccpoly_setiv` validated the IV's length against a fixed `8 ||
12`, not against what the state was actually set up with. `chacha_setiv`
reads exactly `state.ivwords*4` bytes (fixed at `ccpolysetup()` time from
the *setup* IV's own length) — set up with a 12-byte IV, then call
`ccpoly_setiv` with an 8-byte array, and `chacha_setiv` reads 4 bytes
past the end of that Limbo array. Memory-unsafe, reachable, and shipped
in the primitive-6 commit. Fixed to check `f->iv->len !=
is->state.ivwords*4` instead. **Not re-executed as a live "before" test**
— unlike every other negative control in this plan, reproducing the
buggy path means actually executing an out-of-bounds read, not just
computing a wrong-but-safe answer, so this one was confirmed by reading
`chacha_setiv`'s source directly (`load(&s->input[16-ivwords], iv,
ivwords)`, `ivwords` words = `ivwords*4` bytes) rather than by running it
before the fix. The fix itself is confirmed live: a mismatched-length IV
now cleanly raises an exception, caught in `ccpolytest(1)`'s new
setiv-mismatch case.

Same review also found **zero test coverage of `aesgcm_setiv`/
`ccpoly_setiv`** — every case in both `aesgcmtest(1)`/`ccpolytest(1)`
called `*setup()` fresh per encrypt, never `*_setiv()` on a live state,
which is exactly the pattern a real TLS record layer needs (one state
per connection direction, `setiv` per record — skip it and you get GCM's
classic nonce-reuse failure). Added a same-key/different-IV case to
each: encrypt on IV1, `setiv` to IV2, encrypt again on the *same* state,
confirm the second ciphertext matches IV2's vector and explicitly does
NOT match what IV1's keystream would have produced. `aesgcmtest(1)` is
now 8/8, `ccpolytest(1)` 7/7. Also fixed a small asymmetry the same
review flagged: `aesgcm_encrypt`/`ccpoly_encrypt` returned silently on a
nil buffer (leaving `tag` unwritten) while their `_decrypt` counterparts
correctly error — now both error, so a caller can't walk away treating
an unwritten tag as authentic.

**Invariant the setiv coverage established, worth remembering when the
record layer is built**: the second encryption in each new setiv case
matches its expected vector exactly — not approximately, byte-identical
to what a fresh `*setup(key, iv2)` would have produced. Since neither
`aesgcm_encrypt` nor `ccpoly_encrypt` ever mutates the state's stored IV
(both copy it into a local counter/nonce and encrypt from that), this
empirically confirms state-reuse-plus-`setiv` is equivalent to a fresh
setup — exactly the invariant a real record layer depends on: one
`AESGCMstate`/`Chachastate` per connection direction, `setiv` called
once per record, for as many records as the connection lives.

## Why this exists

The user asked for two things in one request: (1) a standing rule that
network clients in this tree never use `#C` as a transport (added to
`CLAUDE.md`), and (2) update the SSL library so that rule can actually be
followed — `module/ssl3.m`/`appl/lib/crypt/ssl3.b` is SSLv3-only (RC4/DES/
3DES/IDEA bulk ciphers, static RSA/DH key exchange, no AES, no GCM/ChaCha20,
no SNI) and cannot complete a TLS 1.2+ handshake with any real HTTPS host,
which is why `bsky(1)`/`masto(1)` were built on `#C` + host `curl(1)` in the
first place.

This doc exists because the work is large enough to span multiple sessions
(read `CLAUDE.md`'s own "picking up cold" convention) — treat this the same
way as `doc/hpc-plan.md`.

## What was measured, not assumed

**Measured 2026-09-01 — a point-in-time fact, not a permanent one.** Servers
change their negotiated TLS configuration over time (a provider disabling
TLS 1.2 entirely, or dropping ECDHE-RSA suites in favor of ECDSA-only, are
both things that happen to real services years apart). If picking this up
much later than the date above, re-run the checks below before trusting the
scope they produced — don't assume they still hold.

Checked directly against the two real target servers (`curl -v`, and
`openssl s_client`), before committing to a scope:

- **TLS 1.2 is sufficient for both.** Neither `bsky.social` nor
  `mastodon.social` requires TLS 1.3 — both happily negotiate TLS 1.2 when
  the client offers only that (`curl --tlsv1.2 --tls-max 1.2`). TLS 1.3's
  different handshake shape (HKDF-based key schedule, no separate
  ServerKeyExchange, 0-RTT machinery) is **not** needed for these two hosts.
- **X25519 alone is sufficient as the key-exchange curve.** Forcing
  `curl --curves X25519` against both hosts still completed the handshake
  successfully. No NIST P-256 (`secp256r1`) support is needed for these two
  targets — a real complexity reduction, since X25519 (RFC 7748) has no
  point validation or cofactor subtleties compared to Weierstrass curves.
- **Both land on ECDHE-RSA key exchange** (RSA certificates, not ECDSA):
  - `bsky.social` → `ECDHE-RSA-AES128-GCM-SHA256` (`TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`, `0xC02F`)
  - `mastodon.social` → `ECDHE-RSA-CHACHA20-POLY1305` (`TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305`, `0xCCA9`)

So the actual implementation target is narrow: **TLS 1.2 client, ECDHE-RSA
key exchange over X25519, AES-128-GCM and ChaCha20-Poly1305 AEAD record
protection.** Anything beyond that (TLS 1.3, ECDSA certs, P-256, CBC-mode
ciphers, DHE finite-field key exchange) is not needed to satisfy the actual
acceptance criterion (reach these two real hosts without `#C`), and adding
it now would be scope invented past what was measured.

## Source to port from, not a from-scratch protocol implementation

Per `CLAUDE.md`'s own "look for an existing mechanism before building one":
a real, mature, working TLS 1.2 client already exists to translate from,
matching this tree's established "translate real Plan 9 C 1:1" practice
(see `doc/`'s notes on the ~19 other p9/cmd translations) rather than
writing a TLS stack from first principles.

Local checkout: **`/Users/npe/src/plan9front/sys/src/libsec/port/`** (a full
9front source tree on this machine, separate from this repo). Confirmed
present and exactly matching the measured target:

- `tlshand.c` (3063 lines) — the TLS handshake state machine.
  `ProtocolVersion = TLS12Version` (0x0303) — 9front's own client caps at
  TLS 1.2, so this is a direct match, not something to trim down from 1.3.
  Offers `X25519` first (`0x001d`) with `secp256r1` as a second choice we
  don't need. Cipher suite table includes exactly
  `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` and
  `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305`.
- `aes_gcm.c` (199 lines) — AES-GCM AEAD.
- `curve25519.c` + `curve25519_dh.c` (570 + 37 lines) — X25519.
- `chacha.c` + `ccpoly.c` (222 + 90 lines) — ChaCha20-Poly1305 AEAD.

This tree's own crypto primitives already cover a good deal of what these
depend on (see next section) — the port is additive, not a wholesale
replacement of `libsec/`.

## What this tree already has vs. the gap

Checked `include/libsec.h` (this tree's own native crypto header, backing
`module/keyring.m` via `libinterp/keyring.c`) and `libsec/` (the native C
implementation) directly:

| Primitive | Have? | Where |
|---|---|---|
| AES (CBC mode) | yes | `libsec/aes.c`, `keyring.m: aescbc` |
| SHA-1/224/256/384/512 | yes | `libsec/sha1.c`, `sha2.c` |
| HMAC-SHA1, HMAC-MD5 | yes | `libsec/hmac.c` |
| **HMAC-SHA256** | **added this session** | `libsec/hmac.c`, needed for the TLS 1.2 PRF |
| RSA, DSA, ElGamal, finite-field DH | yes | `libsec/rsa*.c`, `dsa*.c`, `eg*.c` |
| X.509 cert parsing | yes | `module/x509.m`, `module/asn1.m` (already used by `ssl3.b`) |
| **AES-GCM** | no | port `aes_gcm.c` |
| **X25519 (curve25519)** | **done** | `libsec/curve25519.c`+`curve25519_dh.c`+`tsmemcmp.c`, `keyring.m`/`.c`, verified via `x25519test(1)` |
| **ChaCha20** | **already present, untracked** | `libsec/chacha.c`+`chachablock.c` and `include/libsec.h`'s `Chachastate`/`setupChachastate`/`chacha_encrypt` exist on disk (dated Aug 20, predates this plan - not this session's work, and not staged/committed here per `CLAUDE.md`'s "stage with explicit pathspecs" - someone else's in-flight work, same situation as `os/`). Only **Poly1305** (the MAC half) and the AEAD wrapper (9front's `ccpoly.c`) are still missing. |
| **TLS 1.2 PRF** | no | small, falls out once HMAC-SHA256 exists (RFC 5246 §5) |
| **TLS 1.2 handshake state machine** | no | port `tlshand.c`, adapted to this tree's `Sys->FD`/`module/ssl3.m`-style Limbo interface rather than 9front's native `#a`/`/mnt/tls` convention |
| **Certificate chain verification** | **not done** — see below | |

## The certificate-verification gap (do not ship silently without this)

`appl/lib/crypt/ssl3.b:2347` reads a `# TODO: verify certificate chain`
comment with `x509->verify_chain(...)` **commented out**. A TLS 1.2 client
that negotiates ECDHE+GCM perfectly and does not verify the server's
certificate chain provides encryption with **zero authentication** —
trivially MITM-able — and it will look completely successful in every test
run against the real network, because the tests connect to the real server
regardless.

Two sub-problems, neither solved yet:

1. **Implementing chain verification itself** — `x509->verify_chain` exists
   as a stub/reference but was never finished for `ssl3.b`'s own SSLv3 use.
2. **Where trust roots (a CA bundle) come from.** There is no CA bundle
   anywhere in this tree. Getting one from the host would violate the
   `#C`-as-transport rule a second way (in spirit, if not literally, since
   it'd make the client's trust depend on reaching into the host rather
   than shipping with the client) — this needs an explicit decision, not a
   silent default. Options to weigh when this is reached: ship a frozen
   root-CA bundle in the tree (like a real OS distribution does, needing an
   update story), or something else — not decided.

**Until this is done: no man page may imply the connection is
authenticated, and no test may treat a successful handshake as proof of a
secure connection — only proof of a working handshake.**

## Staging

Revised once primitives 1-2 were done: the record-protection ciphers
(AES-GCM, ChaCha20-Poly1305) only matter *after* the handshake completes —
everything before ChangeCipherSpec is plaintext. So get a real, unencrypted
ClientHello/ServerHello round trip working against a real server *before*
either AEAD cipher, using only the PRF and X25519 — that's what flushes out
extension encoding, the SNI requirement, cipher-suite negotiation, and
record-layer framing, all of which are far more likely to be subtly wrong
than a GCM/ChaCha20-Poly1305 implementation that can be tested offline
against published vectors. A ServerHello naming the expected cipher suite
back is a hard, unambiguous milestone that proves the whole front half
before any bytes are actually decrypted.

1. `hmac_sha256` (native C + `keyring.m`) — RFC 4231 vectors. **Done**
   (`57bfce2f`).
2. TLS 1.2 PRF (built on `hmac_sha256`) — a from-scratch reimplementation of
   RFC 5246 §5 (no published worked vectors exist), cross-checked against
   the host's own `openssl kdf TLS1-PRF` (a real, separate implementation)
   before trusting it. **Done** (`c485fd05`).
3. X25519 — RFC 7748 §6.1 vectors, offline, no network.
4. Just enough of the handshake state machine to send a real ClientHello
   (with SNI) and parse a real ServerHello + Certificate + ServerKeyExchange
   back from `bsky.social` — stopping before any record is actually
   decrypted. Confirms the negotiated cipher suite matches what was
   measured, live, before anything past this point is built on top of an
   assumption. **Hand-roll the wire encoding/decoding for this step rather
   than porting `tlshand.c`'s generic `msgSend`/`msgRecv` framework** — that
   framework is 9front's own reusable abstraction across all handshake
   message types plus the record layer, and porting it whole is a much
   bigger unit of work than this milestone needs; name whatever gets
   written here as a disposable probe (`dialtest(1)`-style — see its BUGS
   section for the pattern) that gets deleted or absorbed once the *real*
   client is ported from `tlshand.c` properly, so it doesn't quietly
   accrete into a bespoke, unreviewed TLS implementation instead. Diff the
   constructed ClientHello against `doc/fixtures/bsky-tls12-handshake.txt`
   byte-for-byte before ever sending it over the wire — differences confined
   to the random/session-id fields and extension ordering are fine;
   differences in extension TLV lengths mean a real encoding bug, findable
   offline instead of by guessing from a live failure. Dial by literal IP
   (`dialtest(1)` found `/net/cs` doesn't resolve names in this emu
   instance — a separate, still-open gap, tracked above, not blocking this
   step since SNI only needs the hostname string, not working DNS).
5. AES-GCM — NIST GCM test vectors / RFC 5288.
6. ChaCha20-Poly1305 — RFC 8439 vectors (`libsec/chacha.c` already covers
   raw ChaCha20; only Poly1305 + the AEAD wrapper are needed).
7. The rest of the handshake state machine (Finished messages, session
   resumption if wanted) plus real record encryption/decryption end to end.
8. Certificate chain verification — the gap above. Decide the trust-root
   question explicitly before this ships as "done."
9. Only then: migrate `bsky(1)`/`masto(1)` off `#C`, per the `CLAUDE.md`
   rule this plan exists to satisfy.

Each step gets its own `appl/cmd/*test.b` (or a native-C test wired the way
`libsec/hmactest.c` already is, if a step is more naturally tested at that
layer) and, per this repo's evidence discipline, a negative control before
being called done.
