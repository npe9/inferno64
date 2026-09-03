# Remaining work: a plan

Written after the networking/crypto/verification arc (SSH client, TLS
1.2, DoH, AWS, the Cryptol and SAW/Dis verification, and the Styx AEAD
record layer). This is the ordered list of what is left, split into
loose ends from that work, extensions of the verification thread, and
the userspace pieces still missing. Each item says the goal, the
approach, rough effort, and how it would be shown to work. Nothing here
is started; it is a plan to pick from.

## A. Loose ends from recent work

These finish things already partly built, so they are the cheapest real
value.

**A1. Styx encrypted mount, end to end.** The chacha20-poly1305 record
cipher in `devssl` and the import/export key derivation are verified
(`ssltest(1)`); a full two-host encrypted `import(4)` mount is not,
because p9any negotiates only to p9sk1, which needs a running auth
server. *Approach:* stand up a local `authsrv` with a p9sk1 key,
register `9export` behind a listener, `import -e chacha20_poly1305` from
a second namespace, read a file byte-exact, confirm a wire tap carries
ciphertext, and a mismatched key fails the mount. *Effort:* medium — the
crypto is done; this is auth-server plumbing. *Risk:* Plan 9 auth setup
is fiddly; time-box it.

**A2. SSH interactive pty session.** `ssh(1)` requests a pty when `$TERM`
is set, but only the piped/no-pty path is verified. *Approach:* drive a
real terminal session inside `vt(1)` against the local sshd, run a
full-screen program (e.g. `vi`), confirm cursor addressing works and the
session tears down cleanly. *Effort:* small — mostly a test harness.

**A3. SSH port forwarding.** `-W host!port` (direct-tcpip) was built and
reverted twice; the relay works but the teardown hangs on a heisenbug
that instrumentation perturbs. *Approach:* this needs the QEMU-gdbstub /
lldb live-debug harness used for the pc64 hunt, not another blind
rewrite — the shape (two-process pump over one fd) is the same one that
also complicates Styx-over-pump, so cracking it pays twice. *Effort:*
unknown until the debugger session; medium-high. *Do not* just
re-attempt the same spawn code.

**A4. SSH ed25519 / ECDSA client keys.** Host keys cover RSA, ECDSA
P-256 and ed25519; client auth is still RSA-only. *Approach:* ed25519
client signing is now tractable because `ed25519(2)` exists — add the
secret-key expansion and the PureEdDSA sign path (watch constant-time,
though for a client key over public transcripts it is lower stakes),
present an `ssh-ed25519` USERAUTH request; verify against a local sshd
that accepts only the ed25519 key. ECDSA signing would follow from
`p256(2)`. *Effort:* medium (ed25519 sign is real crypto).

**A5. SSH known_hosts.** The command pins the host key with `-t` or `-n`
every run; there is no persistent trust store. *Approach:* a
`$home/lib/sshthumbs` file in the 9front `sha256=… server=…` format,
trust-on-first-use with an explicit append, mismatch is fatal. *Effort:*
small.

## B. Verification thread

The distinctive, novel direction — extends fresh, working code.

**B1. SAW/Dis for a whole primitive.** `dis2ll.py` translates only the
straight-line word fragment. *Approach:* add bounded loop unrolling
(SAW supports it) and array/`indx` addressing modelled as LLVM memory
(`llvm_verify` memory contracts), then prove a *complete* primitive as
compiled — the ChaCha20 block function, or SHA-256's compression round —
equal to its Cryptol spec. Nobody has verified Dis bytecode crypto, so
this is genuinely new. *Effort:* large; the loop/array translator is the
work. *Verification:* the SAW proof itself, plus the existing
wrong-spec negative control.

**B2. Cryptol differential for the curve code.** The differential
harness covers the symmetric primitives; it does *not* yet cover the
from-scratch `ed25519(2)`/`p256(2)`, which are the highest-value targets
because they are new and only checked against a few RFC vectors.
*Approach:* X25519 first — Galois ships a vetted `Curve25519` spec, so
it needs only a `cryptovec` x25519 primitive and vendoring; then bespoke
Cryptol `verify` specs for Ed25519 and ECDSA-P256 (compose `PrimeEC` +
the hashes) and differentially check the Limbo verifiers on generated
valid/invalid cases. *Effort:* X25519 small; the verify specs medium.

## C. Network / protocol

**C1. TLS 1.3.** We did 1.2, which reaches most hosts; some are 1.3-only.
*Approach:* new handshake (1-RTT, HKDF, the 1.3 record layer) reusing
the AEAD and curve primitives already present. *Effort:* large.

**C2. Second Styx AEAD (aes-gcm).** Cheap cipher choice: `libsec` has
`aes_gcm`, so it is a second `devssl` entry alongside chacha20-poly1305.
*Effort:* small. Do it if cipher agility is wanted; otherwise one AEAD
is enough.

## D. Userspace still missing

Userspace is broad already (`ed`, `sam`, grep/sed/sort/tr/diff,
gzip/tar/zip, and the `p9/` set: awk, rc, bc, dc, m4, pr, file, iconv,
factor, split, join…, plus the `wm/` apps). The real gaps, most
impactful first:

**D1. A git client.** Nothing does version control. A native `git`
(clone/fetch/pull, then push) over `https(2)`/`tls12(2)` or the SSH
transport would be the single biggest interop win — it is how code
actually moves. *Approach:* the smart-HTTP protocol (`git-upload-pack`
over https) is the tractable start: pkt-line framing, ref advertisement,
want/have negotiation, and packfile parsing (delta resolution is the
hard part). *Effort:* large but high value; build read-only clone first.

**D2. acme.** The iconic Plan 9 mouse-driven editor. `sam` exists;
`acme` does not. *Approach:* it is a Tk/draw + filesystem-interface
program; a real port is large. *Effort:* large. `sam` covers editing, so
this is want-not-need.

**D3. Mail over modern TLS.** Pieces exist (`marshal`, `readmail`,
`sendmail`), but no IMAP/SMTP-over-TLS client. *Approach:* build an IMAP
and SMTP-submission client on `tls12(2)`/`https(2)`, feeding the
existing mail UI. *Effort:* medium.

**D4. PDF / PostScript output, and a viewer.** No print path at all — no
`lp`, no spooler, no PS/PDF writer, and no PDF viewer. A PostScript or
PDF *writer* would also give Charon and the man tools a "save/print
page" capability. *Approach:* a PDF-writer library first (contained),
then a viewer. *Effort:* medium; niche but self-contained.

**D5. scp / sftp.** The SSH client has no file transfer. `scp` (exec
`scp -t`/`-f` on the far side) is the smaller build; sftp is a whole
subsystem. *Approach:* `scp` over the existing `run()`/channel layer.
*Effort:* small-medium.

**D6. A curl-equivalent HTTP command.** `https(2)` exists as a library;
a general `hget`/`curl` command over it (methods, headers, redirects,
output to file) would make the HTTP stack usable from the shell.
*Effort:* small.

**D7. Package manager.** No install/update path (roadmap C6). Lowest
priority; only matters if the tree is distributed to others.

## Suggested order

Close **A1** (finishes the shipped Styx feature) and **A2** (cheap SSH
completion) first. Then pick one flagship: **B1** (novel — verified Dis
crypto) if the interest is formal methods, or **D1** (a git client) if
the interest is making the system practically useful. **A4/B2/C2** are
good medium-sized fill-ins. **A3** waits for a debugger session; **C1**,
**D2**, **D3**, **D4** are large and can be scheduled deliberately.
