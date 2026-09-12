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

**D2. ~~acme.~~ CORRECTION: acme is already here, with source.** This
entry claimed `acme` did not exist. That was wrong and should have been
checked: `appl/acme/` holds the full 32-module Limbo source
(`acme.b buff.b col.b dat.b disk.b ecmd.b edit.b elog.b exec.b file.b
frame.b fsys.b graph.b gui.b look.b regx.b row.b scrl.b styxaux.b
text.b time.b util.b wind.b xfid.b`, each with its `.m`), it builds to
`dis/acme.dis`, and the `acme/` tree at the repository root carries its
support programs (`acme/dis/{adiff,agrep,amail,awd,cd,ind,new,spout,
unind,win,winm}`, `acme/edit/{a,c,d,e,g,i,p,pipe,x}`,
`acme/acid/Acid{,0}`, `acme/mail/{Mail,Mailpop3,mkbox}`), all of which
do resolve to sources under `appl/acme/`. The earlier probe missed it by
looking only in `appl/cmd/`. Nothing to do here.

**D3. ~~Mail over modern TLS.~~ CORRECTION: the client half shipped;
the server half is the gap.** This entry claimed there was no
IMAP/SMTP-over-TLS client. There is: `appl/cmd/upas/fetch.b` (IMAP4
over TLS to an mbox), `appl/cmd/upas/send.b` (SMTP submission over TLS
with MIME compose), `appl/cmd/upas/fs.b` (mbox or IMAP mailbox as a file
tree) and `appl/cmd/upas/nedmail.b`, over `appl/lib/imap4.b` and
`appl/lib/smtp.b`, all verified against real Gmail and against local
Postfix/Dovecot. What is still missing is everything that would make
this box a mail *host*: no `smtpd`, no `pop3d`, no `imap4d`, no delivery
queue (`runq`/`qer`), no `/mail/lib/aliases` expansion, no spam or
attachment filtering. See `doc/upas-plan.md` for the per-component
table. *Effort:* medium-large, and it is a server project, not a client
one.

**D4. PDF / PostScript output, and a viewer.** The "no print path at
all" in the original wording overstated it, though the gap is real.
What exists, checked: `appl/lib/print/` is a genuine print library —
`print.b` (paper/printer/mode configuration), `hp_driver.b` (an HP PCL
raster driver) and `scaler.b` — but its only caller in the tree is
`appl/charon/paginate.b`, so it is Charon's print button and nothing
else. `pslib(2)` (`appl/lib/pslib.b`) writes PostScript, but its entire
interface is one function, `writeimage`, which dumps a `Draw->Image` as
a raster; its only caller is `appl/wm/brutus/image.b`. So: no `lp`
command, no spooler or queue, no text-or-vector PostScript writer, and
no PDF in either direction — no writer and no viewer. *Approach:* a PDF
writer library first (contained), then a viewer; an `lp`-style front end
over the existing `print(2)` config layer is separately cheap.
*Effort:* medium; niche but self-contained.

**D5. scp / sftp.** The SSH client has no file transfer. `scp` (exec
`scp -t`/`-f` on the far side) is the smaller build; sftp is a whole
subsystem. *Approach:* `scp` over the existing `run()`/channel layer.
*Effort:* small-medium.

**D6. A curl-equivalent HTTP command.** `https(2)` exists as a library;
a general `hget`/`curl` command over it (methods, headers, redirects,
output to file) would make the HTTP stack usable from the shell.
*Effort:* small.

**D7. ~~Package manager.~~ CORRECTION: `pkg(1)` shipped.** This entry
claimed there was no install/update path. `appl/cmd/pkg.b` exists and
`doc/pkg-roadmap.md` records milestones M1-M4 as built and tested; the
open work there is the federated Store/Dir/KeyServer design described at
the end of that roadmap, not a missing package manager.

## Suggested order

Close **A1** (finishes the shipped Styx feature) and **A2** (cheap SSH
completion) first. Then pick one flagship: **B1** (novel — verified Dis
crypto) if the interest is formal methods, or **D1** (a git client) if
the interest is making the system practically useful. **A4/B2/C2** are
good medium-sized fill-ins. **A3** waits for a debugger session; **C1**,
**D3** (the mail *server* half) and **D4** are large and can be
scheduled deliberately. **D2** and **D7** are closed — see the
corrections above.

**Two gaps this section never listed, both real (checked, not recalled):**

**D8. Version control.** Nothing in the tree does it — no `git`, `hg`,
`svn` or anything of the kind under `appl/`, `p9/`, `module/` or `man/`.
This is the same point as D1 above, restated so the absence is recorded
as a *category* gap and not only as one candidate implementation. It is
the single largest hole in the environment.

**D9. Job scheduling.** No `cron`, no `at`, no batch queue anywhere in
`appl/`, `p9/`, `module/` or `man/`. Nothing in the system can run on a
timer or at a future time; every recurring task needs an external host
scheduler or a hand-rolled `sleep` loop. *Effort:* small — a `cron`
reading a crontab-shaped table, running entries as the owning user
through the existing `runas`/factotum path, is a contained job.
