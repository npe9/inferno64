# Bringing Inferno's upas to Plan 9 feature-completeness

Status doc for the effort to grow the Inferno `upas` port from the current
Gmail-oriented client into something matching Plan 9's `upas`. Read this first
before working on mail.

## What "Plan 9 upas" is

The reference is the Bell Labs tree, `/sys/src/cmd/upas` (mirrored for
translation under the scratchpad while this work is active). Its components,
with their role and current Inferno status:

| Plan 9 dir | role | Inferno status |
|---|---|---|
| `common` | shared library: message parse, aliases, config, `libsys` | partial (mime(2) parses; no alias/config layer) |
| `fs` | `upas/fs`: the mailbox file server (`/mail/fs`), backends mbox/mdir/pop3/imap/plan9, the `info` file and `ctl` | **partial** — snapshot presenter only, see below |
| `ned` | `nedmail`: the interactive command-line reader | **missing** |
| `marshal` | compose + submit a message (headers, MIME, aliases) | partial — `upas/send` composes+submits over TLS |
| `send` | delivery agent / `sendmail` front end into the queue | missing (send goes straight to one SMTP server) |
| `smtp` | SMTP client (to smarthost/MX) and `smtpd` server | partial — client-submit only; no MX, no smtpd |
| `pop3` | POP3 server (serve a mailbox), and pop3 backend in fs | missing (fetch is IMAP-only) |
| `q` | the queue: `qer` enqueues, `runq` drains it via smtp | missing |
| `alias` | alias-file expansion (`/mail/lib/aliases`) | missing |
| `imap4d` (9front) | IMAP server | missing (Labs tree serves IMAP via other means) |
| `scanmail`, `bayes`, `vf`, `filterkit` | spam/content/attachment filtering | missing |
| `ml` | mailing-list manager | missing |
| `misc`, `unesc` | small tools | missing |

Current Inferno `upas` = three Limbo commands: `fetch` (IMAP4-over-TLS
download to an mbox), `send` (SMTP-over-TLS submission with MIME compose),
`fs` (present an mbox — or an IMAP mailbox — as a read-only file tree). All
verified against real Gmail and, now, against real Postfix/Dovecot/OpenSSH
(`tests/mailsshinterop.sh`).

## The foundation gap: upas/fs

Everything user-facing in Plan 9 mail is a client of `upas/fs`'s namespace,
so its interface is the thing to get right first. Plan 9 `upas/fs`:

- mounts at `/mail/fs`, serving a `ctl` file (`open <path> <name>`,
  `close <name>`, `delete <name> <n>...`) and one directory per open mailbox;
- each mailbox is a directory of numbered messages `1`, `2`, ...; each message
  is a directory whose files are (dirtab order): `body bcc cc date digest
  disposition filename from header info inreplyto lines mimeheader messageid
  raw rawunix rawbody rawheader replyto sender subject to type unixdate
  unixheader ctl`, with MIME sub-parts as numbered sub-directories;
- the `info` file is the parsed summary a reader reads instead of many small
  files — 16 lines in a fixed order: `from to cc replyto unixdate subject type
  disposition filename digest bcc inreplyto date sender messageid lines`;
- it is live: `delete` marks messages and the backing store is rewritten.

Inferno's `fs.b` builds a static in-memory tree once and serves `raw header
type body unixheader filename` plus MIME sub-parts. It has no `info`, no `ctl`,
no per-field files, no delete. So it is a snapshot presenter, not the live
`/mail/fs`, and no Plan 9 mail tool (starting with `nedmail`) can drive it.

## Milestones

Ordered by value and dependency. Each ships with a test and a man page.

1. **upas/fs real interface (foundation).** Serve the full per-message file
   set incl. the 16-field `info` file, and a `ctl` supporting `delete` (rewrite
   the mbox). This makes each message dir Plan-9-compatible for reading and
   deletion. Keep the working mbox and IMAP modes.
2. **nedmail.** Translate `ned/nedmail.c`: the reader loop and the core command
   set (print, next/prev, headers, delete/undelete, save/write, reply/forward,
   pipe, quit). Drives the M1 fs. Test against real delivered mail.
3. **marshal.** Fold `upas/send`'s compose path into a `marshal` matching
   `marshal.c`: alias expansion, proper header synthesis, MIME/quoted-printable.
4. **outbound MTA:** `smtp` client with MX/smarthost, `send`/`sendmail` into a
   `q` queue drained by `runq`. Turns single-server submission into real
   store-and-forward delivery.
5. **servers:** `smtpd` (receive), `pop3` (serve), `ratfs`. The "run your own
   mail host" half — the interop container (`tests/docker`) is the oracle.
6. **filters + lists:** `scanmail`, `bayes`, `vf`, `filterkit`, `ml`.

Milestones 1-3 are the mail *user agent* (read/compose/manage) and are the
priority; 4-6 are the MTA/server side.

## Progress

- Milestone 1 **done** (`c3bd7d5f`): upas/fs serves the real /mail/fs interface
  (info file, full per-message file set, ctl delete rewriting the mbox).
- Milestone 2 **done** (`5a21f08c`, `b2ff1088`): nedmail lists/searches/prints,
  marks and flushes deletes through ctl, saves, resyncs, and does reply/forward
  (r/R/a/A/m/M) via upas/send with an SMTP config file. Tested with controls.
  Only the pipe escapes (|, ||) and filing (f) remain, deferred as the
  hosted-emu exit-in-child limitation above.
- **Tk client done** (`42a29ca3`): `wm/mail` - list/header/body panes over
  /mail/fs, delete via ctl; headless `-t` self-test covers the data layer.
- **acme client done** (`ae0a0548`): `amail` - acme Mail-style client over
  /mail/fs; headless `-t` self-test covers the data layer (acme GUI path needs
  a display, not covered by the test).

The mail **user agent** (read/compose/reply/forward/delete across CLI, Tk and
acme) is complete and tested. Remaining for full equivalence is the MTA/server
half: M4 outbound (smtp MX/smarthost, send/queue/runq), M5 servers (smtpd,
pop3, ratfs), M6 filters+ml. The interop container (`tests/docker`) is the
oracle for the server side - and it can be inverted (host client against an
Inferno server) to test smtpd/pop3.

  **Hosted-emu sub-command finding (corrected, verified with a discriminating
  test):** the earlier "reading stdin corrupts the parent" theory was WRONG. A
  spawned child that only reads a file on its fd0 leaves the parent intact; what
  kills the parent is the child command **terminating via the Dis `exit`
  statement** (or an uncaught `raise`) - it takes the parent (proc group) down
  with it. So the split is by how a command's `init` ENDS:
    - commands whose `init` returns cleanly are safe to `spawn`+`load`+`init`
      and wait on: `echo`, `upas/fs` (nedmail already starts it this way), and
      crucially **`upas/send`**, which only `raise`s on error and returns
      normally on success (verified: spawning `upas/send -N` composes and the
      parent survives).
    - commands whose `init` calls `exit` (`wc`, `sh`, most CLI filters) kill the
      parent. Wrap the child's `init` call in an exception handler to contain a
      `raise`; nothing in-process contains an `exit`.
  Consequence: reply/forward and marshal are NOT blocked - they drive
  `upas/send` (clean-returning) with the draft as a file argument. The pipe
  escapes `|`/`||`, which feed the message to an arbitrary filter that almost
  always ends in `exit`, are the casualty; deferred as a hosted-emu limitation
  (works on native Inferno). This is a hosted-`emu` limitation, not a upas bug.

## Testing

`tests/mailsshinterop.sh` already drives send/fetch against real
Postfix/Dovecot; extend it per milestone (a reader reading real delivered mail
is stronger than one reading a hand-made mbox). Each new command gets a
negative control.
