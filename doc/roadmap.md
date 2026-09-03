# Roadmap: finishing the network stack, Charon, and OS gaps

Status: 2026-09-03. This plans three things: (A) finish the remaining
network/TLS work, (B) make Charon a usable modern-web browser, and
(C) the other notable OS gaps. It is grounded in a full read of the
relevant code (Charon's ~24k lines, the network daemons, a tree-wide
gap survey) — file/line evidence is cited where a claim drove a task,
and the running emu's actual behavior was checked, not assumed.

The through-line: the TLS/HTTPS/DNS-over-HTTPS/AWS work already landed
(see `doc/ssl-modernization-plan.md`) gives the tree a real, modern,
self-verifying network stack for the first time. Most of what remains
is *connecting existing components to it* — above all Charon, which
today can neither resolve names nor speak modern TLS.

---

## Part A — Finish the network/TLS stack

Ordered by value. Items 1–2 unblock Charon (Part B) and every
raw-`dial` program, so they come first.

### A1. Serve `/net/cs` name resolution from DoH  — HIGH, unblocks Charon

**Why:** `dial(2)` translates `tcp!host!port` by writing to `/net/cs`
(`appl/lib/dial.b:42`). Verified in the running hosted emu: `/net/cs`
is **not served at all** (stat fails) and dial-by-name fails outright
with "invalid IP address" — which is why the whole SSL work dialled
literal IPs or leaned on `$Srv`, and why Charon can't reach a site by
name.

**Correction to the record** (a repeated claim this session was that
"/net/cs doesn't resolve names," which is imprecise): the *machinery*
exists and is real — `cs.b` even has a host-`gethostbyname` fallback
(`cs.b:118-120,460-461` → `emu/port/srv.c Srv_iph2a`). Two things
combine to make dial-by-name fail anyway: (a) `cs` is not started in
the hosted profile, so `/net/cs` is absent; and (b) `appl/svc/net.sh:3`
deliberately skips `ndb/dns` when `/env/emuhost` is set, so even a
running `cs` would resolve only host A-records, not a real independent
DNS. Meanwhile `doh(2)` is a *separate island* serving only the HTTPS
stack. **The real gap is the absence of a unified system resolver.**
Wiring `doh` into `cs` (and starting `cs`) fixes dial-by-name for
*every* client — Charon, telnet, ftpfs, styx mounts, mail — and makes
resolution self-contained instead of dependent on the host stack.

**Good news from the code:** `appl/cmd/ndb/cs.b` (689 lines) already
serves `/net/cs` via `file2chan` (`cs.b:130`), already spawns a
*separate proc per query* (`cs.b:255` `spawn request(...)`) — so the
obvious re-entrancy worry (cs → doh → dial → cs) does **not** deadlock:
the inner dial is to the resolver's literal IP, which `cs` translates
directly without any DNS. And `cs` already delegates name lookups to
`/net/dns` (`cs.b:498 querydns`).

**Plan:**
- Add a DoH path to `cs`'s `querydns()`: when `/net/dns` is absent or
  fails, resolve via `doh(2)`. (Alternative: write a small `/net/dns`
  service backed by `doh` and leave `cs` untouched — cleaner layering,
  slightly more plumbing. Prefer this if `cs`'s querydns is awkward to
  reach.)
- Ensure a literal-IP fast path short-circuits before any DoH call
  (it already must, for the resolver dial to terminate).
- Start `cs` at boot in the hosted profile so `/net/cs` is populated.
- **Test:** a `dial`-by-name from a bare Limbo program resolves and
  connects; negative control: with DoH disabled, name resolution fails
  and literal-IP dials still work. Then confirm Charon reaches an
  HTTP site by name (Part B depends on this).
- **Hazard to verify explicitly:** per-query concurrency must hold
  under load (many simultaneous name lookups), and the resolver dial
  must never recurse into DoH.

Once this lands, `https(2)`'s own DoH-in-`connect()` (already shipped)
becomes belt-and-suspenders; both can coexist.

### A2. Certificate revocation — MEDIUM (the one real security gap)

**Why:** `tls12(2)`/`x509(2)` verify chains but do no revocation
checking, so a revoked-but-unexpired certificate still verifies
(documented in `tls12(2)` BUGS). This is the one item that would
meaningfully harden the security posture.

**Plan (cheapest first):**
- **OCSP stapling** first: the server volunteers a signed OCSP
  response in the TLS handshake (status_request extension). We add the
  extension to the ClientHello, parse the stapled response, and check
  it. No extra network round trip, no responder to reach. This is the
  right first step.
- OCSP-by-fetch and CRL fetching are heavier (extra connections,
  large lists) and can follow only if stapling proves insufficient.
- **Test:** against a host that staples (most large CDNs do), confirm a
  good status; negative-control by corrupting the stapled response.

### A3. AWS breadth beyond S3 — MEDIUM

**Confirmed reachable now:** `sts.amazonaws.com` returns HTTP 403
(AWS's "needs authentication") over our own TLS — i.e. the P-256 work
opened up the AWS endpoints that were X25519-unreachable before. Only
S3 is wired, though.

**Plan:**
- `awsv4(2)` already does the signing; add thin clients for the
  services worth having (STS `GetCallerIdentity`, maybe DynamoDB) as
  `appl/cmd/*.b`, same shape as `s3(1)`.
- Extend `awsv4(2)` with presigned-URL (query-string) signing and the
  streaming-payload (`STREAMING-AWS4-...`) mode for large uploads.
- **Test:** bogus-credential signed request draws AWS's own signed
  error, as `s3test`'s `badauthtest` does.

### A4. HTTP-layer features in `https(2)` — MEDIUM

`https(2)` is one-request-per-connection, no redirects, gzip,
keep-alive, HTTP/2, or client certs. None are needed by the current
clients, but Charon and general browsing want several:
- **Redirects (3xx + Location)** — needed for real browsing (Part B).
- **gzip/deflate content-encoding** — most sites compress; without it
  Charon downloads far more and some endpoints assume it.
- **Keep-alive** — a browsing session opens many requests to one host;
  one-per-connection is slow. (Interacts with the streaming Charon
  needs — see B.)
- Client certificates (mutual TLS) — niche; defer.

### A5. Client feature depth — LOW (feature requests, not gaps)

`bsky`/`masto`: media (post/view images), search, deletes/unlikes/
unfollows, non-home timelines, session caching (bsky logs in fresh
each run → rate limits). `s3`: multipart upload, delete, bucket ops.
Do these on demand; they are additive and each is small.

### A6. Constant-time EC — LOW (not a practical gap today)

`p256(2)` is affine, not constant-time. It only ever *verifies* and
does *ephemeral* ECDH — no long-lived-secret operations — so timing
side channels aren't exploitable here. Only revisit if the tree ever
signs with these curves.

---

## Part B — Make Charon a usable modern-web browser

Charon (`appl/charon/`, ~24k lines of Limbo) is a real, shipped,
menu-launchable browser (Charon → `/Apps/!Web`, `lib/wmsetup:87`) with
its own HTML parser, layout engine, JavaScript engine (`jscript.b`),
image decoders, and cookie store. But it is stuck in the late-1990s
web, and two blockers make it unable to load most sites *at all*:

Verified state (from a full read of `appl/charon/`): Charon is a
**Netscape Navigator 3–class browser** — HTML 4.0, ECMAScript 3, a
Netscape-3 DOM, SSLv3, and **no CSS**. It degrades HTML5 to readable
flow "soup" rather than failing, but modern styled/scripted pages are
out of reach without real work. The cheap wins are all in transport.

### B1. Transport: cannot resolve names or speak modern TLS — CRITICAL, cheap

- **Name resolution:** Charon dials via `DI->dial` → `/net/cs`
  (`http.b:288`), which doesn't resolve names here. **Fixed by A1.**
- **TLS:** HTTPS goes through `ssl3`, and `vers` is **hardcoded to 3
  (SSLv3)** right before the handshake (`http.b:338`), overriding the
  config — so it always negotiates SSLv3, with no SNI. Modern servers
  refuse the handshake outright.

**Plan (the single biggest win):** swap the ssl3 transport for
`tls12(2)`. This is well-scoped — `tls12->Session` exposes
`read(buf,n)`/`write(buf,n)`/`close` (`tls12.m:67-69`), a near drop-in
for `ssl3->Context.read/write`, and `tls12->client(fd, hostname,
suites)` takes the real hostname, giving the **SNI** ssl3 lacks. The
ssl3 touch points to port, all in `http.b`: the import (`:9`), load/
init (`:317-321`), `Context.new`/`use_devssl`/`Authinfo`/`.client`
(`:333-339`), reads (`:568-569,:1007`), writes (`:477,:908`),
`HTTP_Header.read/write` carrying `sslx: ref SSL3->Context`
(`:233-234,:777,:874`), `iossl` flag, `ssl_getline` (`:985`),
`tunnel_ssl` proxy CONNECT (`:376`), teardown (`:982`). Charon streams
responses for progressive render, so keep its own HTTP parsing; just
replace the TLS object under it.
- **Test:** load a real ECDSA HTTPS site end to end, cert verified;
  negative-control against a wrong-cert host.

### B2. HTTP correctness — HIGH, and mostly cheap

Verified gaps in `http.b`:
- **Chunked transfer-coding is NOT decoded** (`http.b:545-583` reads
  raw bytes; `Transfer-Encoding` never acted on). Chunked is the
  HTTP/1.1 default from many servers, so responses corrupt today. This
  is arguably the *first* fix — and cheap: port the chunked decoder
  already written for `https(2)` (`appl/lib/https.b readchunked`).
- **gzip/deflate not requested or decoded** — `Accept-Encoding` is
  never sent (`http.b:437-462`), `Content-Encoding` never decoded.
  Also cheap: an inflater is already in-process (`img.b` loads
  `/dis/lib/inflate.dis` for PNG). Send `Accept-Encoding: gzip` and
  inflate the body.
- **No keep-alive** — `TPersist` is declared but never used
  (`http.b:71`); every request opens a fresh connection. Performance,
  not correctness; defer, but note it interacts with A4.
- Already present and working: redirects (cap 10, loop detection,
  `chutils.b:1308-1322`), cookies (`cookiesrv.b`), Basic auth. POST is
  `x-www-form-urlencoded` only (no multipart/file upload).

### B3. Rendering: CSS + HTML5 + layout — LARGE

Verified: **no CSS at all.** `<style>` is explicitly unimplemented and
its contents skipped (`build.b:1180-1183`); `<link rel=stylesheet>` is
in the silently-ignored list (`build.b:1500-1501`); `style=`/`class=`
are captured (`build.b:1755-1786`) but never interpreted for rendering.
All styling is procedural from presentational HTML (`<font>`, `bgcolor`,
`align`, `<center>`) via a font stack (`build.b:2018-2049`). The parser
is HTML 4.0 (`lex.b:17-116`) with no HTML5 elements, but unknown tags
survive as flow text (`lex.b:900-904`). Layout is flow + **floats**
(`layout.b:678-907`) + **HTML tables** (`layout.b:34+`) + frames; no
box model, flex, grid, or positioning.

A full modern CSS+layout engine is a multi-year effort, out of scope.
Pragmatic goals, in order of value-per-effort:
1. **Inline `style=` + a `<style>` block** covering the common
   properties: color, background-color, font-family/size/weight,
   text-align, margin/padding, and crucially `display:none`. Even
   without a real box model this fixes how a large fraction of pages
   *read*. Wire it into build.b's existing font/color stack rather than
   rewriting layout.
2. **HTML5 tag tolerance** — map `section/article/header/nav/footer/
   main/aside/figure` to generic block containers and the inline ones
   to inline, so semantics/flow survive instead of flattening.
3. Only then a real box model (margins/padding/borders as CSS), then
   simple `float`/`inline-block` via CSS. Flexbox/grid are a stretch
   goal, not a near-term target.

### B4. JavaScript / DOM — LARGE, low priority

Verified: the engine is **ECMAScript 3** (`/appl/lib/ecmascript/`) —
no `JSON`, no `Array.forEach/map`, no `Object.keys`, no `bind`, no
`let/const`/arrow/promises — with a **Netscape-3 DOM Level 0**
(`jscript.b:176-390`): `document.forms/images/links/cookie/write`,
`window`, `location`, `history`, `navigator`, `Form`, `Image`. **No
`getElementById`, `querySelector`, `createElement`, `innerHTML`,
`addEventListener`, `XMLHttpRequest`, or `fetch`.** Any site built on a
modern framework is dead.

Realistic stance: a modern JS engine + live DOM is not a reasonable
target for this tree. The pragmatic goal is only that a failing script
never breaks page rendering (it largely doesn't today — scripts are
sandboxed to `document.write`/form/nav). Adding a minimal live DOM
(`getElementById`, `createElement`, `addEventListener`, `innerHTML`)
would be the highest-value JS step *if* pursued, but it should rank
below CSS.

### B5. Images, fonts, text — MOSTLY FINE

Verified good: GIF (**animated**, interlaced), JPEG (**progressive**),
PNG (`img.b:57-131`). UTF-8/Unicode text and multi-charset decoding via
`Convcs` work well. Gaps: **no WebP/AVIF/SVG/BMP/ICO**; `<font face=>`
ignored, **no web fonts** (`@font-face`/TTF/WOFF), and Inferno's bitmap
fonts are **not anti-aliased**. Priorities here are low; WebP decoding
is the most likely to matter (many sites now serve it), and SVG is
common but large to implement.

Also absent (all confirmed): `<video>`/`<audio>`, `<canvas>`/WebGL,
WebSockets, Web Storage/IndexedDB, service workers, HTTP/2-3. None are
near-term targets; they're listed so the plan is honest about the
ceiling — Charon can become a good browser for *content* sites, not for
web *applications*.

---

## Part C — Other OS gaps

From a tree-wide survey. Hosted-emu items are actionable here; native
items are informational (owned elsewhere). Several tie neatly into the
crypto/network work just done.

**First, what is NOT a gap** (present and real — don't "fix" these):
Acme, Sam, ed/sed editors; the Limbo and full kencc C toolchains, a
Dis debugger (`mdb`), profilers; factotum-based auth and secstore;
namespace/capability sandboxing (`newns`, `devcap`); local filesystems
(kfs, FAT via `dossrv`, ISO9660, venti, tarfs, styx/9p). And several
absences are deliberate Inferno scope, not deficiencies: no NFS/CIFS
(styx/9p *is* the network fs), no Python/Lua (Limbo is the language),
no SSH-as-transport (styx-over-TLS is the model). Don't plan work
against those.

**Actionable hosted-emu gaps, prioritized:**

### C1. Unified name resolution — HIGH (same as A1)
Covered above. The single highest-leverage OS fix; it's the network
item and the OS-gap item at once.

### C2. Modern file encryption / signing — MEDIUM, and now cheap
`appl/cmd/auth/aescbc.b` is the only file-crypto tool and is dated:
AES-CBC + HMAC-SHA1, no AEAD, no passphrase KDF (`aescbc.b:1-4`). But
the TLS work just added **AES-GCM and ChaCha20-Poly1305 AEAD** to
`keyring(2)`, and `hmac_sha256`/the PRF give a KDF — so a modern
`age`/`signify`-style tool (AEAD file encryption with a passphrase KDF,
and detached public-key signatures) is now a small, natural follow-on
that reuses the exact primitives already landed and tested. High
value-per-effort.

### C3. Image/media encoders — MEDIUM
Decoders are decent (GIF/JPEG/PNG read), but **write is GIF-only** —
no JPEG or PNG *encoder* (`appl/lib/writegif.b` is the only one). A PNG
encoder (the inflate/deflate lib is already in-process) complements the
existing decoders and Charon, and is a contained task. Audio is
raw-PCM/IAF only (no MP3/AAC/Opus/FLAC decode); video is MPEG-1 only.
Modern audio/video codecs are large and lower priority.

### C4. SSH — DONE (client)
An SSH-2 *client* now exists, in Limbo, on this tree's own crypto:
`ssh(2)` (`appl/lib/ssh.b`) and the `ssh(1)` command
(`appl/cmd/ssh/`). Ported from 9front's `ssh.c`, it speaks the modern
OpenSSH default stack — curve25519-sha256 key exchange, `ssh-rsa` host
keys verified `rsa-sha2-256`, and the `chacha20-poly1305@openssh.com`
cipher (on three raw ChaCha20/Poly1305 keyring builtins added for it,
`chachatest(1)`). It does the full transport (`connect`), publickey
authentication from a PEM RSA key (`login`), and one-shot remote command
execution (`run`), an interactive shell (`shell`, the Plan 9
telnet(1)/vt(1) model — the client does no terminal emulation, it sets
raw mode and shuttles bytes), and `factotum(4)` authentication (the
private key never leaves the agent; `-i` file keys are the fallback).
Host keys may be RSA, ECDSA P-256 (`ecdsa-sha2-nistp256`, verified with
the existing `p256(2)`), or ed25519 (`ssh-ed25519`, verified with a
new from-scratch `ed25519(2)` — neither this tree nor 9front's libsec
had Ed25519, so it is a pure-Limbo twisted-Edwards implementation on
IPint, in the style of `p256(2)`, passing RFC 8032's own vectors in
`ed25519test(1)`). All three modern host-key types are reachable.
Verified end to end against real OpenSSH `sshd`s (`tests/sshlocal.sh`):
an RSA host, an ECDSA-only host and an ed25519-only host each connect
with the thumbprint pinned to `ssh-keygen`'s fingerprint, plus
`Accepted publickey`, command output/exit, interactive shell, factotum
auth, and unauthorised-key / corrupted-signature negative controls.
Still open (noted in `ssh(2)` BUGS): mid-session window-size relay,
ed25519 and ECDSA *client* keys, port forwarding, and an SSH *server*.

### C5. Printing / document output — LOW-MEDIUM
No print path at all: no `lp`, no spooler, and no PostScript/PDF
generation (and no troff — the `eqn*` files in the tree are unrelated).
A PostScript or PDF writer would also give Charon a "print/save page"
capability. Contained but niche.

### C6. Packaging — LOW
No dependency-managed package manager; `appl/cmd/install/` is a signed
file-tree distribution mechanism, and everything else is mk-from-source.
This is largely by design for a research OS; only worth revisiting if
third-party software distribution becomes a goal.

**Native-OS, informational (owned elsewhere, not planned here):** USB
is UHCI/USB-1.1-only on `os/pc` (USB2/3 only under osprey/manga); wifi
is vintage WaveLan; no Bluetooth anywhere. These matter only for the
native kernel ports.

---

## Suggested order of execution

The theme: the first cluster makes Charon actually able to load the
modern web, and it leans almost entirely on network components that
already exist — so it's high-value and low-invention.

1. **A1 / C1** (DoH-backed `/net/cs`, and start `cs`) — unblocks
   dial-by-name for *every* client, Charon included. Highest leverage.
2. **B2 chunked + gzip** — the cheapest Charon fix and a real blocker:
   port the `https(2)` chunked decoder and use the already-in-process
   inflater. Without this many HTTP/1.1 responses corrupt.
3. **B1** (Charon → `tls12`) — with A1, Charon then loads modern HTTPS
   with SNI and cert verification.
4. **A4 redirects/gzip in `https(2)`** — mostly overlaps B2; keeps the
   two HTTP stacks consistent.
5. **B3 step 1** (inline + `<style>` basic CSS) — pages become
   readable instead of unstyled soup. The biggest rendering win.
6. **C2** (AEAD file-encryption/signing tool) — cheap, reuses the new
   AES-GCM/ChaCha20/HMAC-SHA256 primitives; high value-per-effort.
7. **A2** (OCSP stapling) — closes the one real security gap.
8. Everything else on demand: AWS breadth (A3), client feature depth
   (A5), PNG encoder (C3), deeper CSS then a minimal live DOM (B3/B4),
   SSH client (C4), print/PDF (C5).

Items 1–5 are what take Charon from "can't load the modern web" to
"loads and reasonably renders many real content sites." Web
*applications* (framework SPAs) remain out of reach without a modern
JS/DOM, which is not a realistic target for this tree — the honest
ceiling is a good browser for content, not for apps.
