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

`gpu(3)` is now in the **`emu-g` manifest too**, not just `emu-cocoa`. That
makes the whole GPU stack testable headlessly, and — because `emu-g` links no
`win-gpu.m` — it is the only configuration in which `devgpu.c`'s no-hardware
path actually runs. That path was previously unreachable, which is how it came
to report the wrong precision for as long as it did.

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
request) what it would *actually* deliver and **declines the GPU** when that is
worse than asked. Consequence worth knowing: **`backend gpu` alone does not use
the GPU**, because `precision` defaults to `f64`. Ask for `precision f32`.

The `P` answer is now unconditionally `f32`. It used to report `f64` whenever no
hardware hooks were linked, reasoning that the portable fallback loop is written
in `double` — but `U` and `X` carry values as 32-bit singles on *every* path, so
that told an f64 caller it was getting f64 while handing back f32. Latent rather
than active on this platform (only `emu-cocoa` builds `devgpu.c`, and it always
links `win-gpu.m`, whose constructor registers the hooks), but it would fire the
moment `devgpu` is built without a hardware backend — a Linux port, or adding
`gpu` to the `emu-g` manifest. Real f64 needs new tags with 8-byte values.

---

## Plan — remaining

1. **Scheduler deadlock (see below).** Now localised to a lost `vmq` push, with
   the next three steps written out — but *not* a prerequisite for the rest.
   It blocks runtime validation of anything **concurrent**, and items 2–5 are
   not: they are single-threaded numerics plus a device. Do it when a
   concurrency change needs validating, or when someone has the patience for a
   ~12% reproducer; do not let it block the GPU work again.
2. **Device-resident vectors — this is items 2 and 4 together, and doing
   either alone is wrong.** `dot`/`axpy`/`norm` still run on the CPU, and the
   plan used to list "put them on the GPU" as its own item. Measured, that
   framing is wrong in both directions.

   Timing `cgsolve`'s loop split between `apply()` and the five vector ops,
   `fem(2)` Poisson, `emu-cocoa` with real Metal:

   | backend | mesh | apply | vector ops | vector share |
   |---|---|---|---|---|
   | cpu f64 | 24³ | 50ms | 2ms | 3% |
   | cpu f64 | 30³ | 110ms | 14ms | 11% |
   | gpu f32 | 24³ | 15ms | 9ms | **36%** |
   | gpu f32 | 30³ | 23ms | 16ms | **40%** |

   So the item is real — offloading the matvec turned the vector ops from
   background noise into 40% of the solve, textbook Amdahl, and they now cap
   what any faster matvec can buy. But **offloading them one at a time would
   make it slower, not faster**: each is O(n) arithmetic and a round trip is
   O(n) transfer, so a `dot` that ships a vector to compute one scalar is pure
   loss. The current `apply()` already pays that twice per iteration.

   The only shape that wins is keeping the vectors *device-resident for the
   whole solve*: upload `b` and `x0` once, run the CG recurrence against vector
   handles, and bring back only the scalars the convergence test needs. That
   subsumes old item 4 (keep the matrix resident) because it is the same
   mechanism — handles that outlive a call — and it also removes the
   per-matvec transfer, which is what `apply()`'s 23ms at 30³ mostly *is*:
   800k nonzeros is about 1.6 MFLOP, trivial for the GPU, so 0.44ms per matvec
   is overhead, not arithmetic.

   Rough ceiling, so nobody expects too much: at 30³ the solve is 67ms against
   the CPU's 128ms (1.9×). Making the vector ops free takes that to about 2.5×;
   the rest needs the transfers gone too. `dot` also needs a real parallel
   reduction kernel, which is the one genuinely new piece of Metal here.

   Note this is measured for **CG only**. GMRES does far more vector work per
   iteration (Arnoldi orthogonalisation is O(k) dots and axpys at restart
   length k), so the fraction there should be higher — expected, not measured.
3. **`amr(2)` and `pde(2)` on GPU.** Both are *stencil* sweeps, not SpMV, so
   they need a second Metal kernel — and no matrix upload at all, so the
   per-call overhead that dominates small SpMV problems mostly disappears.

   **"One kernel serves both" was written here as an assumption and it is
   false.** The arithmetic matches (`c + h*D*lap`, second-order central
   differences, explicit Euler, substepped) but the memory contract does not:

   - `amr(2)` blocks carry a real **1-cell ghost halo** (`(bs+2)³`, filled by
     `exchange()` before the sweep), so its inner loop does no boundary tests
     at all. `pde(2)`'s `Field` is **unpadded** `nx*ny` and routes all five
     stencil reads through `get()`, which branches on `f.bc` per access
     (periodic modulo / zero / clamp). Those are different kernels, and you
     cannot simply pad `Field`: its exact length is load-bearing outside
     `pde.b` — `krylov->solve` takes `f.u` as x0/rhs directly, and `verify.b`
     indexes it as `iy*n+ix`. Padding it is an API break reaching into
     `krylov(2)` and `verify(2)`.
   - 2-D 5-point versus 3-D 7-point.
   - `pde` has one `(dx,dy)` per launch; `amr`'s `(dx,dy,dz)` is per block,
     from the block's level.

   The contract that *does* work for both: **launch per contiguous padded
   region, take `(nx,ny,nz,dx,dy,dz,h,D)` as launch parameters, and require
   the caller to have filled a 1-cell halo first.** `amr` already satisfies it
   exactly; `pde` needs a new padded scratch buffer plus an O(perimeter)
   "materialise the BC into a halo" step per substep, which keeps `f.u`'s
   public layout intact. Cheap, but it is a real new buffer and copy, not
   free reuse.

   Also: only `diffuse()` maps cleanly. `wave()` needs two input levels and a
   three-way rotation; `gray()` needs two coupled fields, a nonlinear term and
   per-cell clamping. Three kernels minimum on the `pde` side for all of them.

   Before benchmarking, know that `amr`'s CPU baseline is unfairly slow for
   reasons unrelated to the kernel: `sweep()` calls `exchange()` and then
   `step()` calls it again, and each substep allocates and zero-fills a fresh
   `(bs+2)³` array per block and copies it back. Fix or measure around those,
   or the GPU will look better than it is.

   `verify(2)`'s `laplacianorder()` is the regression test to extend — it
   isolates exactly this stencil and asserts second-order convergence, which
   is a real numerical assertion rather than a smoke test. `amr(2)` has **no
   tests at all**; `amr.m` documents `totalmass` as the conservation
   invariant for verification and nothing calls it. Note its coarse/fine
   prolongation is not flux-conservative, so measure the CPU drift first
   rather than blaming a port for it.
4. *(folded into item 2 — the matrix and the vectors need the same
   device-resident-handle mechanism, and the measurement there says the
   vectors are the part that now matters.)* Today `apply()` also re-uploads the
   matrix per solve, which UQ and convergence studies pay repeatedly.
5. Possibly: f64 emulation or mixed-precision refinement, so `precision f64`
   can use the GPU instead of declining it.

---

## Open bugs

### 1. Scheduler deadlock under concurrent fd use — **blocks the rest**

Reproducer committed: `appl/cmd/fdstresstest.b`, `man/1/fdstresstest`.

**A single run is not the reproducer.** One run almost certainly prints `PASS`
and tells you nothing. Loop it. A normal run takes 0.2s, so anything past a
couple of seconds is the failure — **a hang is the failure**: no output, no exit.

Measured rates, 150 runs each:

| flags | hung |
|---|---|
| `-c0` (interpreter) | 18/150 — **12%** |
| `-c1` (JIT, **the default** `cflag`) | 57/150 — **38%** |

**Reproduce and validate under `-c1`, not `-c0`.** It is both the default
configuration and three times more likely to fail, so it is far cheaper to
falsify a candidate fix against. Most of the analysis below was done under `-c0`
because the interpreter is easier to reason about; the JIT emits non-atomic
refcount code (see the GC-LOCK HISTORY comment in `dis.c`), so a `-c1`-only
difference would be its own finding — but the hang occurs on both, so the
scheduler bug is not JIT-specific.

```sh
for i in $(seq 1 150); do
	./MacOSX/arm64/bin/emu-g -c1 -r . /dis/fdstresstest.dis >/dev/null 2>&1 &
	pid=$!
	ok=0
	for t in $(seq 1 40); do
		sleep 0.25
		kill -0 $pid 2>/dev/null || { ok=1; break; }
	done
	[ $ok = 0 ] && { echo "hung: $pid"; break; }   # leave it alive to attach
	wait $pid 2>/dev/null
done
```

Any test sharing an `Fgrp` across processes hits it, which is why it gates the
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

**The push is what is lost, and it is lost in `vmq` specifically.** Measured by
temporarily giving `Proc` a counter per blocking site and per waking site, then
reading them off a hung process. One representative capture:

```
blocks   acquire 481   iyield+startup 119   Sleep 3   qlock 2
readies  rel-vmq+iyield 480   rel-idlevmq 119   Wakeup 3   qunlock 2
```

Read that carefully, because it settles several things at once:

- `acquire` blocked 481 times and was woken 480. **Deficit of exactly one, in
  `vmq`.**
- `idlevmq` balances exactly (119/119). The bug is not there.
- `Sleep` (3/3) and `qlock` (2/2) balance exactly. **The shared-semaphore theory
  is dead** — no other blocking point stole the token. It was never sent.
- Since the wakeup was never sent and the proc is on no queue, the *push* was
  lost, not the pop.

The same capture recorded what `acquire()` saw at that push: `vmq` was a
single-element list `[X]` and the proc linked itself onto `X`. `X` was later
popped, but `vmq` did not then become `[stuck]` — so `X`'s link field stopped
pointing at the stuck proc between the push and the pop.

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

- **Not `Proc.qnext` aliasing — this was tried and it failed.** `qnext` really
  is shared between the scheduler's `vmq`/`idlevmq` (`dis.c`) and `qlock`'s wait
  queue, and `qlock` (`emu/port/lock.c:58`) writes the *tail proc's* `qnext`,
  not only its own — the one place in the tree that writes another proc's link.
  That is a real aliasing hazard and it matches the symptom exactly, so it was
  fixed: `Proc` got a separate `vmqnext` used only by `vmq`/`idlevmq`.
  **It made no difference**, so the change was reverted rather than left in the
  scheduler as unearned churn. Measured interleaved, same machine, same session,
  alternating binaries run pair by pair so load hits both equally:

  ```
  150 pairs, -c0:   baseline 18/150 hung     with vmqnext 23/150 hung
  ```

  Do not re-derive this. If you want the aliasing cleaned up on its own merits,
  fine — but it is hygiene, not this bug.

So: the push is lost from `vmq` while `isched.l` is held by both the pusher
(`acquire`) and every popper (`release`, `iyield`). Either that mutual exclusion
is not holding, or something outside those three touches the list. Both are
worth checking directly, and neither has been.

**Next step**, in order of cost:
1. Re-run the per-site counters (they cost one `int` increment each and did *not*
   make the hang go away — verified) and this time also record, at the lost
   push, whether `isched.vmqt` was actually reachable from `isched.vmq`. That
   distinguishes "linked onto a stale tail" from "linked correctly then unlinked".
2. Audit every read/write of `isched.vmq`/`vmqt` for one not under `isched.l` —
   note that `acquire()` deliberately manipulates `runhd`/`runtl` *unlocked*
   after `osblock()`, and `tready()`/`execatidle()` read scheduler state
   unlocked, so unlocked access to this struct is already normal here.
3. Only then consider `lock()`/`_tas` themselves. `_tas` (`emu/MacOSX/asm-arm64.s`)
   is a correct `ldaxr`/`stlxr` acquire loop, though it abandons the exclusive
   monitor without `clrex` on the contended path; `unlock()` is `coherencefn()`
   then a plain store.

Do not patch speculatively: even at 38% a change cannot be falsified by a
handful of runs. Any candidate needs the interleaved A/B above — 150 pairs,
both binaries alternating in one session so machine load hits them equally —
run under `-c1` for the stronger signal. The `vmqnext` attempt looked obviously
right and was wrong.

### Reproducing and instrumenting it

A normal run takes 0.2s, so a hang is unambiguous. Loop `emu-g`, poll every
0.25s, treat >10s as hung, and leave the first hung process **alive** to attach
to (`kill` leftovers by pid — another session may share this Mac).

`sample <pid>` gives threads; lldb gives the data. The debug-map warning about
`main.o` is harmless, but it does mean globals defined in `emu/port/main.c`
(such as `procs`) are not visible — reach procs through the `tramp(arg=...)`
argument in each thread's backtrace instead.

```
lldb -p <pid> -b -o "p isched" -o "thread backtrace all"
lldb -p <pid> -b -o "expr -- (void)osready((Proc*)0x...)" -o "detach"
```

Two traps worth knowing. `emu/MacOSX/mkfile` has an **empty `HFILES`**, so
editing `emu/port/dat.h` does *not* trigger a rebuild — you can silently get a
binary whose object files disagree about `struct Proc`'s layout. Alternating
`CONF` forces a full recompile, which is why it worked here; do that
deliberately. And lldb truncates a large struct print, so `p *(Proc*)0x...`
will appear to be missing fields that are really there — print the fields
individually, or check with `type lookup Proc`.

**It contaminates other measurements — classify hangs separately.** Any
concurrent test in this tree inherits this hang, so a pass/fail count lumps it
in with whatever you were actually measuring. That happened: `gputest(1)`'s
A/B first read as "no improvement, and the fix looks slightly worse", because
~10% of *both* arms were this hang. Separating hangs from real failures turned
the same data into 9/100 → 0/100 on the metric that mattered. Count
`timeout`'s exit 124 as its own category, never as a failure of your change.

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

### 4. `trapUSR1` takes a non-local exit from an async signal handler

Found while chasing the hang above; **not** its cause (a hung process was caught
with a counter showing zero SIGUSR1 deliveries in the whole run), but real.

`trapUSR1` (`emu/MacOSX/os.c`) calls `disfault(nil, Eintr)` when a SIGUSR1
arrives with no interrupt posted — a case its own comment calls "Should never
happen". `disfault` with `Eintr` reaches `exits(0)`, which is plain libc
`exit()`. Since the emu links with `-Wl,-alias,___wrap_free,_free`, **every
`free` in the process is emu's pool allocator**, so `exit()`'s own cleanup
re-enters `poolfree`. If the signal lands while that thread is already inside
the allocator, `exit()` blocks on the pool lock the interrupted thread itself
holds, and every other thread then spins in `lock()` forever.

That is not hypothetical: a separate hang was captured in exactly that shape —
the pool lock at `val == 1` with no owner running and seven threads spinning in
`lock()` from `poolfree`/`dopoolalloc`. Whether that one was caused by this path
was never established.

### 5. Heap corruption in the allocator under concurrency (`emu-cocoa`)

New, found by `gputest(1)`. Under `emu-cocoa` that test fails almost every run
— 0 of 6 on a build with **no gpu changes at all**, so it is neither the test
nor this session's work. Under `emu-g` the same test passes 89 of 100.

**It is not `gpu(3)`-specific either.** `fdstresstest(1)`, which never touches
the device, crashes the same way under `emu-cocoa`. That is much rarer — one in
about fifty runs against nearly every run for `gputest` — and the difference is
most likely allocation pressure: `gputest` runs 40 procs against 60 buffered
matvecs each, which is far more malloc/free traffic than 16 procs opening
`/dev/null`. Same measurement, `emu-cocoa`, 12 runs of `fdstresstest`:

```
pass 7   hang 4   crash 1
```

On hang rates, be careful what that supports: 4 hangs in 12 is a wide interval,
and it is **not** distinguishable from the 38% measured for `emu-g` under
`-c1`. It is above `emu-g`'s `-c0` figure of 12%, and that is all the data
carries. What `emu-cocoa` clearly *is* harsher for is the crash, which `emu-g`
has not produced at all.

```
disfault: native backtrace:
  trapmemref
  _sigtramp
  dopoolalloc + 92
  kmalloc + 68
  kstrdup + 48
  kproc + 272
  Sys_open + 48
  rmcall / xec / vmachine / tramp
disfault: sys: segmentation violation addr=0x434f4e4c
```

Two things to notice. The faulting address `0x434f4e4c` is **ASCII text**
(`CONL`) being followed as a pointer — a corrupted allocator free list, not a
null or a stray offset. And the path is `Sys_open` → `release()` → `kproc()` →
`kstrdup` → `kmalloc`, which is the *same* `Sys_open`/`release` path as open
bug 1's lost wakeup. Whether the hang and this corruption are one bug or two is
**not established** — but they are close enough together that finding one may
well explain the other, and this one has the advantage of being a crash with a
native backtrace rather than a silent hang.

**A poisoned free list caught the write, and the data names it.** Set
`INFERNO_POOLPOISON=1` (added for this; off by default, `emu/port/alloc.c`) and
every free block's dead payload is filled with `0xa5` and checked when the
block leaves the free tree. Running `gputest(1)` under `emu-cocoa` produced:

```
POOLPOISON pooldel: block 107e2dd00 size 128 ... allocpc=0x10261d758
bytes: 42 f2 00 00 43 10 00 00 43 29 00 00 43 44 00 00 43 61 00 00 ...
ascii: B...C...C)..CD..Ca..C...C...C...C...C...........
```

Those are big-endian IEEE754 singles: `0x42f20000` = 121.0, `0x43100000` =
144.0, `0x43290000` = 169.0, and on to 400.0 — that is 11², 12², … 20².
`gputest`'s matvec check expects exactly `y[i] = (i+1)²`, and big-endian f32 is
what `put32f` writes. **So a `gpu(3)` matvec response is being written into
memory that is already on the free list.**

Two obvious explanations were then tested and **both are wrong**. Do not spend
time on either again:

- **Not the JIT's non-atomic refcounts.** `dis.c`'s GC-LOCK HISTORY comment
  notes the AINC/ADEC atomics cover only the interpreted path, which predicts
  the corruption should be far rarer under `-c0`. It is not. `gputest` under
  `emu-cocoa`, poison on, 10 runs each: `-c1` 2 passed with 1 poison report,
  `-c0` **0 passed with 1 poison report**. The interpreted path corrupts just
  as much.
- **Not a slice temporary passed to a released syscall.** Both `gputest` and
  `gpu.b` read with `sys->read(fd, rbuf[off:], ...)`, and a slice descriptor
  collected while the VM is released would explain everything. Rewriting the
  read to pass the array with no slice at all changed nothing: 1 of 10 passed
  either way, 1 poison report either way.

The strongest clue left is the **`emu-g` / `emu-cocoa` asymmetry**, because the
one thing that differs about *producing this particular data* is that under
`emu-cocoa` the reply comes from Metal (`metal_spmv`) and under `emu-g` from
`devgpu.c`'s own C loop. The next experiment is therefore to run `emu-cocoa`
with the Metal compute hooks forced off, so the same binary and the same Cocoa
environment produce the reply through the C path: if the corruption follows the
Metal path it is in `win-gpu.m`, and if it stays it is environmental. That needs
a few lines in `gpucompute_init()` to honour an env var, and is worth having
permanently as a way to compare the two backends in one build.

Two warnings about the tool itself, both learned the hard way:
- It poisons only the payload *past* the tree links, because those are live
  while a block sits in the tree. A use-after-free that writes at offset 0 —
  the most likely kind — is invisible to it.
- Filling the *whole* block cost a **275× slowdown** (`fem(2)` assembly 14ms →
  3845ms), which moved the bug rather than finding it. It now fills at most
  `Poisonmax` (128) bytes, costing about 1.35×, which is what made the hit
  above possible.

Why `emu-cocoa` is worse than `emu-g`: the Cocoa build runs the AppKit main
thread and Metal's own worker threads on top of the same allocator, so it is
simply more concurrent. That also makes it the better place to chase this.

**Do not reach for lldb first.** Three attempts to catch the fault under the
debugger produced no crash at all — the run hangs instead. The debugger changes
the timing enough to move the bug, the same way a watchdog did for open bug 1.
What did work was letting emu's own `trapmemref` handler print its native
backtrace. If you need more than that, the allocator already carries
`MAGIC_A`/`MAGIC_F` block magics and a `poolaudit()` (`emu/port/alloc.c`);
asserting the magic at the top of `poolfree()` would catch the corruption
nearer its source than a segfault deep in a free-list walk, and costs one
compare. Note `poolfree()` currently *reads* neighbour magics to decide whether
to coalesce and silently declines when they are wrong, so corruption there is
detected and ignored today rather than reported.

Related but separately confirmed *not* the cause: `win-gpu.m`'s Metal
initialisation used a hand-rolled `if(gpu_ready != 0) return` one-shot, which
by inspection lets several first-uploads run the whole body at once and
overwrite `gpu_device`/`gpu_queue`/`gpu_pipe` under each other, with no barrier
before publishing `gpu_ready = 1`. That is now a `dispatch_once`.

**But that race was never observed to fire, and the note should not pretend
otherwise.** The old guard was instrumented with a counter of how many times
the body ran, and tested under `gputest(1)` on `emu-cocoa` — including a
variant whose *first* GPU use is the concurrent phase, to rule out the obvious
explanation that the single-threaded precision check initialises Metal first.
Twelve runs, never entered more than once; something upstream serialises the
first upload in practice. So `dispatch_once` is a correctness fix by
inspection, nothing more, and definitely not the cure for the corruption above.

### 6. `panic: decref` — seen once, not attributed

Observed exactly once, in `gputest(1)` under the default `-c1`. A refcount went
negative. Not reproduced since: 30 further runs (15 with the current tree, 15
with a pre-`gethandle` binary) produced none, and it is **not** attributable to
this session's `devgpu` work, which touches no refcounts.

Worth recording anyway because there is an obvious suspect already written
down: `dis.c`'s own GC-LOCK HISTORY comment notes that the AINC/ADEC atomics
cover only the interpreted `-c0` path, and that the arm64 JIT still emits plain
non-atomic load/modify/store for the same `h->ref` field. `-c1` is the default.
So this is the predicted symptom of a known, deliberately unfixed gap, and
anyone seeing it again should reach for that comment first rather than treat it
as new.

### 7. Smaller, noted, unfixed

- ~~`metal_present_geom()` consumes `mtl_zclear` before creating its encoder~~
  **fixed.** All three geom passes (`metal_present_geom`, the 3-D triangle
  pass, and the sprite loop) now consume the pending depth clear only once the
  encoder exists, so a pass that never happens leaves the clear pending instead
  of dropping it. Verified by forcing encoder creation to fail on every other
  3-D pass and counting clears actually lost: **0 of 1000 with the fix, 500 of
  1000 without** — the exact half the forced failure rate predicts. The other
  half of the original note was wrong and is dropped: using the encoder without
  a nil check is harmless, because messaging nil is a no-op in Objective-C.
  (A first attempt at that probe was itself wrong — it nil-ed `enc` *after*
  creating a real encoder, which leaks it and trips Metal's
  "released without endEncoding" assertion. Force the failure by not creating
  the encoder at all.)
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
