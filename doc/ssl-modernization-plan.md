# SSL/TLS modernization plan

## Status (most recent first)

**In progress.** `module/keyring.m`/`libinterp/keyring.c`/`libsec/hmac.c`
gained `hmac_sha256` (primitive 1 of the staging list below), verified
against 4 real vectors (`hmacsha256test(1)`, RFC 4231 case 1 + 3 generated
from the host's own `openssl(1)` as an independent oracle), negative-
controlled. Nothing else landed yet. `bsky(1)`/`masto(1)` still drive host
`curl(1)` through `#C` — see `CLAUDE.md`'s own rule, which this plan exists
to satisfy.

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
| **X25519 (curve25519)** | no | port `curve25519.c`/`curve25519_dh.c` |
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

## Staging (one primitive per commit, tested against published vectors, no
network needed until the full handshake is assembled)

1. `hmac_sha256` (native C + `keyring.m`) — RFC 4231 vectors.
2. TLS 1.2 PRF (built on `hmac_sha256`) — RFC 5246 §5's own vectors /
   cross-checked against a real TLS library's intermediate values if RFC
   vectors are thin.
3. AES-GCM — NIST GCM test vectors / RFC 5288.
4. X25519 — RFC 7748 §6.1 vectors.
5. ChaCha20-Poly1305 — RFC 8439 vectors.
6. Only then: the handshake state machine itself, built on 1-5, tested
   first against a byte-captured real handshake transcript before ever
   dialing out.
7. Certificate chain verification — the gap above. Decide the trust-root
   question explicitly before this ships as "done."
8. Only then: migrate `bsky(1)`/`masto(1)` off `#C`, per the `CLAUDE.md`
   rule this plan exists to satisfy.

Each step gets its own `appl/cmd/*test.b` (or a native-C test wired the way
`libsec/hmactest.c` already is, if a step is more naturally tested at that
layer) and, per this repo's evidence discipline, a negative control before
being called done.
