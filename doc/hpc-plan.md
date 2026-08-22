# Numerics, GPU offload, and open bugs — plan and progress

Written 2026-08-21. Read this first if you are picking the work up cold; it is
meant to be enough on its own. Commit hashes are on the `inferno-rio` branch.

Everything below was built in this tree, not ported, unless it says otherwise.

---

## How to build and run

```sh
export PATH=$PWD/MacOSX/arm64/bin:$PATH

cd appl && mk install          # Limbo. Never invoke limbo(1) by hand: the tree
                               # builds with -z (see "Gotchas") and mkfiles/mkdis
                               # carries the flags.
cd emu/MacOSX && mk install                # emu-cocoa (GUI, has the GPU device)
cd emu/MacOSX && mk CONF=emu-g install     # emu-g (headless). BUILD BOTH.
cd libinterp && mk install                 # then relink emu
```

`emu-g` is headless and does not link libdraw; `emu-cocoa` does and owns the
Metal code. Anything touching `emu/port/main.c` or another shared file must be
built both ways — a change that only compiled under Cocoa broke the headless
link once already (`a6395f88`).

Run something:

```sh
./MacOSX/arm64/bin/emu-g   -r . /dis/sh.dis -c 'temple/numericstest'
./MacOSX/arm64/bin/emu-cocoa -r . /dis/gpubench.dis 24
```

Big problems need heap: `-pheap=1073741824 -pmain=536870912`.

---

## What exists

### Numerics stack (all with `man/2` pages)

| module | what it is | commit |
|---|---|---|
| `mesh(2)` | 2-D grid spec language (`mesh 64x64 domain 1x1 bc clamp`) | earlier |
| `pde(2)` | problem-spec language: diffuse / wave / Gray-Scott, explicit + implicit | earlier, `561780c7` |
| `krylov(2)` | real GMRES(m) + CG, **matrix-free** (`Apply` closure) | earlier |
| `femesh(2)` | structured hex8 mesh: nodes, elements, connectivity | `23e8d557` |
| `sparse(2)` | CSR matrix: build pattern once, refill values, matvec, Dirichlet | `23e8d557` |
| `fem(2)` | **miniFE-shaped**: real hex8 assembly (shape fns + 2×2×2 quadrature) into CSR, solved by `krylov` against the matrix's own matvec | `23e8d557` |
| `amr(2)` | **miniAMR-shaped**: block AMR, refine/coarsen, 2:1 balance, cross-level ghost exchange, explicit diffusion sweep | `ff350858` |
| `uq(2)`, `verify(2)`, `meshview(2)` | Monte-Carlo UQ, convergence-order study, field→pixel palette | earlier |
| `gpu(2)` | execution-target command language (`device`/`precision`/`resident`) | `20db47fe` |
| `sequencer(2)` | Caerwyn Jones's CSP synthesizer, ported | `f7c4e01f` |

Shell access for most of these: `appl/cmd/sh/{mesh,pde,fem,gpu,uq,verify,synth}.b`,
documented as `sh-*(1)`.

**Scope deliberately excluded**: no MPI-analog anywhere. miniFE and miniAMR are
serial kernels by explicit decision — this tree has no distributed-memory story,
and inventing one was judged a different project, not an extension.

### GPU offload — working, and faster than the CPU

- `gpu(3)` (`emu/port/devgpu.c`) — Styx device, `/dev/gpuclone`. One handle per
  uploaded matrix; matrix uploads once and stays resident, only the vector
  crosses per matvec. Commit `0992a316`.
- `emu/MacOSX/win-gpu.m` — real `MTLComputePipelineState`, one GPU thread per
  matrix row, plugged in via nullable `gpuhw*` hooks (same convention
  `devdraw.c` uses for `gpudrawfillpoly3d`). Commit `8785cb06`.
- Binary wire format, commit `eef811eb`. 32-bit ints, IEEE754 single, big-endian
  — exactly what `math->export_int`/`export_real32` emit.

Measured with `gpubench(1)`, cpu f64 vs gpu f32:

```
mesh      nodes    cpu     gpu
12x12x12   2197     4ms    32ms
16x16x16   4913    10ms    26ms
20x20x20   9261    26ms    26ms   <- break-even
24x24x24  15625    52ms    35ms
30x30x30  29791   128ms    62ms   <- 2.1x
```

**Offloading is a loss below ~9k nodes.** Per matvec the win is larger than per
solve, because f32 costs iterations (52 vs 42 at 30³).

Metal has no `double`, so the hardware path is f32-only. `gpu(2)`'s `precision`
verb is therefore load-bearing, not decoration: `apply()` asks the device (`P`
request) what it would *actually* compute in and **declines the GPU** when that
is worse than asked. Consequence worth knowing: **`backend gpu` alone does not
use the GPU**, because `precision` defaults to `f64`. Ask for `precision f32`.

---

## Plan — remaining

1. **Scheduler deadlock (see below) — do this first.** It blocks runtime
   validation of anything concurrent, which is most of what is left.
2. **`krylov(2)` vector ops on GPU.** `dot`/`axpy`/`norm` still run on the CPU.
   Once matvec is offloaded these are the remaining serial part; a solve that
   ships the vector back and forth per operation will not scale.
3. **`amr(2)` and `pde(2)` on GPU.** Both are *stencil* sweeps, not SpMV, so
   they need a second Metal kernel — but no matrix upload at all, so the
   per-call overhead that dominates small SpMV problems mostly disappears.
   One kernel should serve both.
4. **Keep the matrix resident across solves.** Today `apply()` re-uploads per
   solve; UQ and convergence studies solve the same matrix repeatedly.
5. Possibly: f64 emulation or mixed-precision refinement, so `precision f64`
   can use the GPU instead of declining it.

---

## Open bugs

### 1. Scheduler deadlock under concurrent fd use — **blocks the rest**

Reproducer committed: `appl/cmd/fdstresstest.b`, `man/1/fdstresstest`.

```sh
timeout 30 ./MacOSX/arm64/bin/emu-g -c0 -r . /dis/fdstresstest.dis
```

Hangs ~1/10 under `-c0`. **A hang is the failure** — no output, no exit. Any
test sharing an `Fgrp` across processes hits it, which is why it gates the
concurrency work.

**It is a single lost `osready`, and that is now proven, not inferred.** lldb
was attached to a hung `emu-g` and the missing wakeup injected by hand:

```
(lldb) expr -- (void)osready((Proc*)0x104e20fa0)
(lldb) detach
```

The run completed normally and immediately. Nothing else about the state was
touched, so nothing else was wrong.

Full state at the hang (`lldb -p <pid>`, `p isched`, plus a script walking
`head`/`vmq`/`idlevmq` by `next`/`qnext`):

- `tready(0)` → **0**. `runhd == nil`, `vmq == nil`. The scheduler believes it
  is legitimately idle.
- Two progs: pid 1 `Precv` (waiting on the channel pid 3 would send to), pid 3
  **`Prelease`**.
- Nine threads: one `main` in `ospause`, six vmachine kprocs parked in
  `iyield`'s `osblock` on `idlevmq`, one asleep on `isched.irend` in the
  vmachine loop (the holder), and one — the proc owning prog pid 3 —
  parked in `acquire`'s `osblock` at `dis.c:1033`, reached from
  `Sys_open` → `mcall` → `xec`.
- That proc: `text = "acquire"`, `qnext == nil`, **on no queue**, and
  `((Sem*)p->os)->v == 0` — no token ever arrived.

So the proc pushed itself onto `vmq`, and then left `vmq` without anyone
calling `osready` on it. Every path that clears `vmq` (`release()`, `iyield()`)
calls `osready` on what it popped, so either a pop lost its wakeup or the push
itself was lost.

Already ruled out — do not re-check:
- **Not a lost semaphore wakeup.** `osblock`/`osready` are a proper counting
  semaphore: `pthread_mutex` + `v++`/`while(v==0) cond_wait` + `v--`. An
  `osready` arriving before the `osblock` is counted, not dropped.
- **Not two sleepers on one `Rendez`.** `Sleep()` (`emu/port/proc.c:28`)
  `panic`s on `r->p != nil`, so that state would abort, not hang.
- **Not a lost `Wakeup`.** `Sleep` evaluates its predicate under `r->l` and
  `Wakeup` takes `r->l`; and `tready()` already tests `vmq`, not just `runhd`.
  At the hang `tready()` is 0 anyway, so the irend handshake is not implicated.
- **Not `isched.vmqt` going stale.** It is only read when `vmq != nil`, and
  `acquire()` reassigns it on every push to an empty queue.
- **Not a thread dying while holding the VM.** `progexit()` returns into
  `vmachine`'s `waserror` loop; it does not exit the thread.
- `incref`/`decref` are lock-protected; not `Chan` refcounting.
- `addrun`/`delrun` not taking `isched.l` is *by design* — only the slot holder
  touches the run queue.

Live suspect, not yet confirmed: **`Proc.qnext` is shared** between the
scheduler's `vmq`/`idlevmq` (`dis.c`) and `qlock`'s wait queue
(`emu/port/lock.c:55`), and `osblock`/`osready` are likewise shared between
`acquire`, `iyield`, `qlock` and `Sleep`. One semaphore serving four distinct
blocking points means a token delivered for one can be consumed by another. No
overlap has been demonstrated yet — find one before changing anything.

**Next step is a scheduler event trace**, not more code reading: record
push/pop/park/ready per `Proc` under the `isched.l` that is already held, and
dump the ring at the hang. That says directly whether the pop happened.

Not patched speculatively: at 1-in-10 a change cannot be falsified by running
the test. Any candidate fix needs 50+ runs each side plus a negative control
confirming the unpatched build still hangs in the same session — and `-c1` is
the default `cflag`, so validate there too or say plainly that you did not.

Reproducing on demand: `emu-g` in a loop, 15s per attempt, stop at the first
survivor and attach. `sample <pid>` gives the threads; lldb gives `isched`.
Kill leftovers **by pid** — another session may share this Mac.

### 2. `Screen.newwindow()` returns nil after a resize

Rare, unfixed. No longer silent: all five Limbo call sites now report the reason
(`8ad7019e`). The error *was* always propagated via `%r`; every caller discarded
it. `INFERNO_DRAWDEBUG=1` turns on libdraw's own diagnostics.

### 3. draw3d intermittently rendered 0 of 60 segments

Seen twice, never reproduced under control. Three hypotheses tested and
disproved (first run after recompiling; consecutive runs; first run after 100s
idle). A failed Metal pass now warns once per process and counts in
`INFERNO_METAL_STATS`, so a recurrence will say whether a fallback was involved.
`appl/cmd/line3test.b` guards the working path.

A real ordering bug *was* found next to it and fixed (`66acdf8c`): the GPU
readback overwrote `gscreen` with the texture *after* the CPU fallback had drawn
into it, discarding the fallback. Do not assume that was the reported symptom.

### 4. Smaller, noted, unfixed

- `metal_present_geom()` consumes `mtl_zclear` before creating its encoder and
  uses the encoder without a nil check — a failed encoder loses that frame's
  depth clear.
- `metal_queue_line`'s queue-full path busy-waits on the UI thread draining it.
- `man/3/ip.original` looks like a stray backup file; regenerating section 3's
  index would pick it up as a second `ip`.

---

## Gotchas that cost real time

**Limbo `int` is 64-bit here.** `WORD` is `intptr`; `include/interp.h` still has
`typedef int WORD; /* 32 bits */` commented out. `math->export_int`/`import_int`
cast to C `int*` and mangled every multi-element array (`[1,2,3,4]` →
`[1,2,0,0]`) until `1561fcaa`. **Anything else casting Limbo array data to C
`int*` has the same bug.**

**`array[n] of T` is not zeroed** unless compiled with `limbo -z`. `doc/dis.ms`
specifies `newa` as leaving non-pointer space undefined; the zeroing `newaz`
existed all along and simply was not used. `mkfiles/mkdis` now passes `-z`
(`fc3f4dab`). Read the in-tree spec before calling something a bug.

**`int` of a `real` rounds, it does not truncate.** Use `math->floor`.

**Reserved words that look safe**: `load`, `to`, `fn`, `big`.

**Sibling `for` loops** in one function cannot both `:=` the same name.

**`sh(1)`**: `${cmd}` for substitution builtins, not backquote; `=` is a
metacharacter; `for`/`if`/`while` come from `load std` and take braced blocks.

**troff**: `.TQ` does not exist here — use two `.TP`. Inside `.EX`, write `\en`
not a raw escape, and never start a line with `'` or `.`. Verify with
`groff -man -Tutf8 -k -ww`.

**`man/*/INDEX` files are hand-curated.** Do not regenerate wholesale — raw
generator output for section 2 is ~835 lines against the ~500 committed.

**GUI evidence on this host**: the accessibility API reports zero windows
whether or not things work, and screenshots go black with no error when the
screen locks. Use `readpixels` on an image — it depends on nothing outside the
process.

**Instrumentation that makes a bug vanish is a data point, not a fix** — adding
a watchdog to `fdstresstest` stopped the hang reproducing entirely.

**`os/` is not ours** — see `CLAUDE.md`. `emu/` is.

---

## Test commands

All follow the `appl/cmd/*test.b` convention and have `man/1` pages.

| command | checks | notes |
|---|---|---|
| `keyuptest` | key-release events not inserted as text | GUI; verified by negative control |
| `nowmtest` | no-window-manager draw context works | GUI; proves drawing via `readpixels` |
| `line3test` | draw3d GPU line provider vs software | GUI; counts *segments*, not pixels |
| `fdstresstest` | the scheduler hang | **hangs on failure**, run under `timeout` |
| `gpubench` | cpu vs GPU solve timings | not pass/fail, prints numbers |
| `temple/numericstest`, `temple/smoketest` | pre-existing | |

A pixel count once reported a renderer dropping *every* segment as "120% of
software". Count the thing that actually differs.
