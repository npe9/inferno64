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

### GPU offload — working, and now a loss at every size that fits here

**Read this before doing any more GPU work.** The measurements below that made
offloading look like a win were taken against a CPU matvec written in Limbo.
`sparse->matvec` now calls `math->spmv`, a C builtin, and is **9-10x faster**
(commit follows this note). Re-measured against that baseline, `gpubench(1)`
says:

```
mesh       nodes   cpu f64             gpu f32
                   solve   us/iter     solve   us/iter
12x12x12    2197    0-1ms      -       3-4ms     176
16x16x16    4913    1-1ms     45       5-8ms     200
20x20x20    9261    2-3ms     71      6-12ms     188
24x24x24   15625    5-6ms    147      7-18ms     179
28x28x28   21952  10-11ms    250     10-23ms     222   <- per-matvec crossover
30x30x30   27000  13-15ms    310     13-25ms     250
32x32x32   32768  17-18ms    378     15-28ms     288   <- per-solve crossover
```
Best of five solves per row; the range is the spread across those five.

Read the **per-iteration** columns, not the per-solve ones.

This table took three attempts and the first two were wrong, which is the more
useful thing recorded here. Version one compared Metal against an *interpreted*
matvec. Version two fixed that but reported 74ms for the GPU at mesh 12 against
30ms at mesh 24 — a smaller problem taking longer — and explained it as per-call
overhead; it was the *one-time* cost of setting up Metal, landing on whichever
solve ran first and divided by that mesh's iteration count. Version three fixed
that with a discarded warm-up run but took **one sample per size** of a quantity
that varies by a third run to run, and timed a 5ms solve with a 1ms clock: the
per-iteration figures it produced (219–282us) were noise, and a "flat" claim
drawn from them was not supported by its own data.

`gpubench(1)` now discards a GPU solve, then runs each solve five times and
reports the best with the range. The variance is all upward, as contention
noise is, so the best is the clean measurement.

Version four extended the range, and reversed the conclusion. "`gpubench` panics
at mesh 28 and above" was written here three times as a fact about the machine.
It was a **bug**: `poolsetsize` took a C `int`, so `-pheap=2g` arrived negative
and `-pheap=4g` arrived as zero, and the size check then reported "not enough
memory" for a mesh needing a few megabytes. Fixed (`uintptr` throughout,
`strtoull` instead of `atoi`, and a `g` suffix), and meshes up to 32 now run.

So: **the GPU does pay, from mesh 28 up.** Below that its cost per iteration is
flat (176-200us across a sevenfold range), which is what per-call overhead looks
like, while the CPU's grows with the problem, which is what arithmetic looks
like. They cross per matvec at 28 cubed (250 against 222) and per solve at 32
cubed (17ms against 15ms). Two cautions on that last one: it is f32 against f64
with 52 iterations against 45, so they are not the same solve; and the GPU's
spread is far wider (15-28ms against 17-18ms), so the win is on the best of five
and not on the worst.

The earlier "no break-even at any size that fits in memory here" was true only
because of the pool bug. **A ceiling nobody questioned hid the answer for four
versions of this table.**

None of the GPU work is wrong and none of it should be deleted: the device, the
Metal kernel, the residency and the precision query all do what they say. What
changed is the baseline they were being compared against, and with an honest
one they do not currently pay. **Items 2 and 3 below both need re-deriving from
this table rather than the old one.** The most likely conclusion is that the
per-call overhead has to go before anything else matters, which is a different
piece of work from making the vector operations resident.

The old table, kept so the change is legible — same code, Limbo matvec:

```
mesh      nodes    cpu     gpu
12x12x12   2197     4ms    32ms
16x16x16   4913    10ms    26ms
20x20x20   9261    26ms    26ms   <- break-even
24x24x24  15625    52ms    35ms
30x30x30  29791   128ms    62ms   <- 2.1x
```

### What the GPU offload is

- `gpu(3)` (`emu/port/devgpu.c`) — Styx device, `/dev/gpuclone`. One handle per
  uploaded matrix; matrix uploads once and stays resident, only the vector
  crosses per matvec. Commit `0992a316`.
- `emu/MacOSX/win-gpu.m` — real `MTLComputePipelineState`, one GPU thread per
  matrix row, plugged in via nullable `gpuhw*` hooks (same convention
  `devdraw.c` uses for `gpudrawfillpoly3d`). Commit `8785cb06`.
- Binary wire format, commit `eef811eb`. 32-bit ints, IEEE754 single, big-endian
  — exactly what `math->export_int`/`export_real32` emit.

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

1. **Scheduler deadlock — FIXED.** `unlock()` had no release barrier: it called
   `coherencefn()`, which is `nofence`, an empty function, on every platform.
   On arm64 a critical section's stores could therefore become visible after
   the store releasing the lock, so the next holder read state the previous one
   had not yet published — and a proc pushed onto `isched.vmq` could vanish
   from it with nobody popping it. One line: the release store is now a release
   store. 150 interleaved pairs at `-c1`: **67 hangs to 0**. See below for the
   evidence and for how three earlier attempts missed it.

   **This unblocks concurrency validation**, which this list has been routing
   around. It is also worth re-measuring open bugs 5 and 6 against it before
   spending any more time on them: `gputest`'s six baseline crashes, `decref`
   among them, do not occur with the fix.
2. **Device-resident vectors — live again, but only above mesh 28.** This item
   was suspended when `math->spmv` made the CPU faster than the GPU at every
   size then measurable. Raising that ceiling changed the answer: the GPU wins
   per matvec from 28 cubed and per solve from 32, so the vector operations
   riding along with an offloaded matvec matter again. Re-derive the 40% from
   the current table before building anything — it was measured on the old one.
   The argument below about round trips is what still holds; its numbers do
   not.

   **Device-resident vectors — this is items 2 and 4 together, and doing
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
   **Measured before designing any of this, and it resized the item.** The 40%
   figure was suspected to be Limbo heap traffic, since every vector op
   allocated a fresh `array of real`. It is not: an in-place `axpy` costs 32.0us
   against the allocating one's 33.0us at 13824 elements, so **allocation is 3%**
   and a bare `array[n]` is 0.5us. The cost is the generated code. (The JIT
   matters enormously and was already on: the same loop interpreted at `-c0`
   costs 421us, 14x more.)

   **What the measurement found instead: `math(2)` already had `dot`, `norm1`,
   `norm2`, `iamax` and even `gemm` as C builtins, and `krylov.b` hand-rolled
   its own in Limbo.** `math->dot` is **3.9x** faster than the JIT-compiled
   Limbo one (7.5us against 29.5us). The one genuinely missing operation was the
   vector update, now added as `math->axpby` (`y = a*x + b*y`, `libmath/blas.c`)
   — **16x** faster than the same loop in Limbo (2.0us against 32.0us), the
   larger factor because a streaming multiply-add vectorises where a reduction
   does not. `axpby` rather than `axpy` because CG needs both shapes: `y += a*x`
   for the solution and residual, and `y = x + b*y` for `p = r + beta*p`, which
   an accumulating form cannot express without destroying `r`.

   End to end on `fem(2)` Poisson at 24 cubed, iteration count and residual
   **unchanged** (34 and 39 iterations, residuals identical to 12 digits, and
   `verify(2)`'s `laplacianorder` still 1.930/1.982/1.996/1.999):

   | backend | before | after |
   |---|---|---|
   | cpu f64 | 54ms | 47ms |
   | gpu f32 | 44ms | 21-31ms |

   The GPU path gains more, which is the Amdahl prediction confirmed from the
   other side: vector ops were 40% of that solve and only 3% of the CPU one.

   **So item 2's ceiling has moved and should be re-derived before building
   device residency.** Two cautions for whoever does. First, the table above
   compares `gpu f32` against `cpu f64` and those are *different solves* — 39
   iterations against 34 — so quote iteration counts with any speedup or measure
   at equal precision. Second, a device-side `dot` as a parallel tree reduction
   rounds differently from a sequential sum, and CG's convergence test reads
   that number, so a changed iteration count can masquerade as a performance
   result; `verify(2)`'s `laplacianorder` is the regression that catches it.

   Left undone deliberately: `dot`'s own kernel in `libmath/blas.c` still uses
   the pointer-walking style, which does not vectorise, and could plausibly
   reach `axpby`'s 2us. Rewriting it with indexed loops and several accumulators
   changes the summation order and therefore the rounding of a long-standing
   published primitive that other code depends on. Worth doing, not worth doing
   silently.

   `krylovtest(1)` is new and covers what none of this had: the solvers
   themselves. It asserts *exact* iteration counts against matrices with a
   chosen number of distinct eigenvalues, which is the property that moves if a
   basis stops being orthogonal — a residual check would not notice. GMRES had
   no test at all before this, and the in-place updates went out without one.

   Reproduce with `vecbench(1)`; the end-to-end figures are `gpubench(1)`. Note
   `gpubench` panics with "not enough memory" at mesh 28 and above on this
   machine regardless of `-pheap`/`-pmain`, and did so before this change too.

   **The bottleneck then moved to assembly, and that has been dealt with too.**
   With the solve at 6ms, `fem(2)`'s assembly was 116ms of a 122ms run — 95% of
   it. Two thirds of that was `sparse->newfrompattern` scanning a per-node list
   of neighbours to test membership, O(degree) with a pointer chase per step:
   about eleven million list traversals at 24 cubed. Replacing it with a
   node-to-element map plus a marker array — **no C at all, just the same work
   done once instead of degree times** — took it from 65ms to 10ms. Making
   `find` binary-search the row it already sorts took the scatter from 38ms to
   21ms. Assembly overall **116ms → 45ms**, producing a bit-identical matrix
   (same residual to every digit).

   `sparsetest(1)` is new and compares the pattern *entry by entry* against the
   old list-scanning implementation, on random rather than grid connectivity —
   a structured mesh delivers neighbours nearly sorted already and would hide an
   ordering mistake. Removing the per-row sort makes it fail on the first
   column, which is the control.

   Note the ordering lesson: the algorithmic fix here was worth 6x and needed no
   C, while the C builtin for `spmv` was worth 9-10x and needed no algorithm
   change. Neither substitutes for the other, and the profile said which to do
   where.

3. **`amr(2)` and `pde(2)` on GPU — the cheap experiment was run, and `pde(2)`
   is now 5-6x faster with no GPU at all.** The recommendation here was to try
   a C stencil builtin before any Metal work. Measured first: `pde(2)`'s
   `diffuseop` — the operator applied once per Krylov iteration — was **78 to
   82 per cent** of a solve, the same Amdahl position `sparse->matvec` had
   been in. `math->lap5` is that stencil in C, and `diffuseop`/`waveop` are now
   two C calls and no Limbo loop: `lap5` for the stencil, then the existing
   `axpby` to combine, since `y = 1*x + (-c)*lap` is exactly its shape.

   | grid | 100 implicit steps, before | after |
   |---|---|---|
   | 128² | 3.41s | 0.58s |
   | 256² | 28.10s | 5.26s |

   Results agree to 5.5e-16 relative after a hundred successive GMRES solves.

   **The explicit steppers were then converted too, and that is where the big
   factor was.** `diffuse`, `wave` and `gray` each called `lap(f,x,y)` per cell,
   which is five `get()` calls with boundary branches plus a call of its own —
   about six Limbo calls per cell — and they *substep* for stability, so one
   `run` is many full sweeps. Precomputing the Laplacian for the whole grid with
   `lap5` and combining with `axpby`:

   | 256², explicit diffuse, 50 steps | before | after |
   |---|---|---|
   | | 54.26s | **0.34s** |

   Bit-identical result. `gray` is bit-identical too; `wave` agrees to 1.3e-15
   across 50 substepped steps. `gray`'s reaction term is nonlinear and per-cell
   so that loop stays in Limbo — only the five-point gather moved.

   **A correction to what the previous commit implied.** It reported
   `laplacianorder` unchanged alongside the `lap5` work, which reads as
   evidence for it. It was not: `laplacianorder` drives `pde->diffuse` on a raw
   `Field`, which at that point still went through the *unconverted* Limbo
   `lap()`. It exercises `lap5` only now that the explicit path is converted —
   verified by perturbing `lap5` by 0.1% and watching the reported orders move
   (1.930 → 1.950). "Unchanged" is only evidence when the code is reached.

   **`lap5` shipped measured on `clamp` alone**, with periodic and zero never
   compared against anything — the border is where such a kernel goes wrong,
   and it is separate code per boundary condition precisely so the interior
   loop can be branchless. `pdetest(1)` now compares every cell against the
   Limbo reference for all three, plus grids one cell wide and a grid that is
   all border. Controls: removing the border walk fails 16 cases, exchanging
   `dx` for `dy` differs in 945 cells.

   What this does **not** settle is the GPU question, which still needs
   re-deriving — but the CPU baseline it would be measured against has just
   moved by 5-6x, which is the same trap the old GPU table fell into. Note
   `amr(2)`'s 3-D seven-point stencil shares none of `lap5`'s code and is now
   `math->lap7`. It is a *different* kernel and deliberately so: an `amr` block
   is a padded cube whose one-cell halo `exchange()` has already filled, so
   there is no boundary handling at all, and the update is fused (`u + a*lap`)
   rather than a bare Laplacian plus `axpby`, because a second pass would have
   to skip the halo and would save nothing. This is exactly the "launch per
   contiguous padded region" contract this plan predicted would work.

   Two other things in `step()` mattered as much as the kernel, and the profile
   said so — 8 substeps came out as stencil 23ms, exchange 8ms, copy-back ~8ms,
   allocation 1ms:

   - `sweep()` called `exchange()` and then `step()` exchanged again at the top
     of its first substep. A whole redundant exchange per sweep, and the entire
     exchange cost when a step took one substep. `sweep` is now just `step`.
   - `step()` copied its result back cell by cell. Nothing reads another
     block's data during the stencil loop — it touches only a block's own
     interior and halo — so the block now simply takes the new array.

   The plan warned that the allocation and zero-fill made this baseline
   "unfairly slow". Measured, that part is 1ms of 40 — the warning was
   overstated; the copy-back it was bundled with was the real cost. The
   zero-fill is now only of the *halo*, since `lap7` writes every interior cell
   itself: 1736 stores a block per substep at blocksize 16 rather than 5832,
   worth about 4%. It is not removed altogether because Dis leaves a fresh
   array of a pointer-free type undefined (`doc/dis.ms`) and correctness must
   not depend on the tree's `-z` — `sparse(2)` already states that rule.

   | 5 sweeps, 4³ roots | before | after |
   |---|---|---|
   | blocksize 8 | 199ms | 44ms |
   | blocksize 16 | 4817ms | 603ms |

   Mass identical to the bit in both.

   **`verify(2)` gained `laplacian7order`.** Everything else only compared
   `lap7` against the Limbo loop it replaced — and *that* loop had never been
   checked against an analytic Laplacian. Two implementations of one
   misunderstanding agree with each other perfectly; a convergence study cannot
   be satisfied that way. Applied to `sin2πx·sin2πy·sin2πz` on a padded cube
   whose halo holds the exact function (removing boundary treatment from the
   measurement, the same purpose periodicity serves in the 2-D study), it
   converges at **1.978 → 1.994 → 1.999**. `pdetest(1)` asserts the last is 2
   within 0.1; `sh-verify(1)` exposes it.

   `pdetest(1)` also compares `lap7` against a
   Limbo reference on padded cubes and, separately, checks that the **halo is
   not written** — a kernel running one cell too far still produces a correct
   interior, so that mistake passes a comparison of interior values and is
   caught only by looking at cells that should not have changed. Controls: a
   `p*p`→`p` stride typo differs in every interior cell; running one cell too
   far is caught by the halo check alone.

   **`amr(2)` now has a test** (`amrtest(1)`), which it never did. It checks
   the 2:1 balance after *every* adaptation pass rather than at the end, by
   scanning all six faces of every leaf and walking the tree to find whatever
   covers the neighbouring region; that a refine/coarsen round trip is exact on
   a field that differs in every cell; and that a constant survives both a
   cross-level exchange and a diffusion step, which is exact whatever the level
   structure and so localises any cross-level mistake to a named cell.

   It also settles the conservation question this plan told the next person to
   measure rather than assume:

   | forest | leaves | mass drift over 20 sweeps |
   |---|---|---|
   | uniform, level 0 | 27 | 5.2e-15 |
   | uniform, every block refined | 216 | 1.0e-14 |
   | adapted around a ball | 608 | **0.052** |

   The drift is **entirely** from coarse-fine interfaces — with none, mass is
   conserved to machine precision. That is the documented scope limit rather
   than a defect, but 5% over twenty sweeps is large enough to know before
   relying on it, and it is now in `man/2/amr` instead of waiting to be
   rediscovered. Control for the balance scan: a forest hand-refined three
   levels deep reports 30 face pairs differing by more than one level.

   **Two documentation bugs on the way, both in `module/amr.m`, both cases of a
   comment outliving the code.** It described `totalmass` as the total cell
   *volume*, omitting the value — which would make it independent of the field
   and useless as an invariant. And it described coarsening as never checking
   cross-neighbour balance, calling that "a real, documented scope limit, not an
   oversight" — long after that had stopped being true. `coarsenlevel()` does
   ask `needsbalance()`, and the guard is load-bearing: removing it leaves
   **272 face pairs differing by two levels**. `amrtest(1)` now drives the
   coarsening path deliberately (refine everywhere, then want only the left
   half, so one side coarsens beside a side that stays deep) rather than leaving
   it to whatever a refinement test happens to touch. `man/2/amr` had both
   right.

   The general lesson, which cost time here: **the module comment was the thing
   I reasoned from, and it was stale.** I went looking for a bug the docs
   promised and spent two experiments failing to reproduce it before reading
   the implementation, which says in its own comment that it was fixed.

   Both are *stencil* sweeps, not SpMV, so
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

   *(All three of these are now fixed — see above. Kept for the reasoning.)*
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
6. **Host-capability devices: the shape, then `ml(3)` and video.** Reaching
   the OS's real capabilities — ANE, VideoToolbox, AVFoundation, camera, Metal
   — from Limbo. The detailed section after this list argues the shape matters
   more than any one device, and that `gpu(3)`'s synchronous single-file RPC is
   **not** the template: it cannot stream, cannot decouple producer from
   consumer, and moves bulk data on every call.

   **This item is done.** Video: still and movie decode in `draw(3)`, AAC
   decode as a filter in `audio(3)`, container parsing in `quicktime(2)`,
   `playmovie(1)` synchronising the two. Inference: `ml(3)` (`devml.c` +
   `win-ml.m`), running on the Neural Engine, verified by `mltest(1)`. Both
   are the same shape — one device per capability, composed through the
   namespace — which is what the section below argued mattered more than
   either device.
7. **Vector instructions in Dis and the JIT.** A separate line of attack on the
   same bottleneck item 2 measures — see the detailed section after this list.
   Short version: start with C builtins in `math(2)`, which need no Dis, JIT,
   spec or compiler change, because the win is dispatch amortisation before it
   is ever SIMD.

8. **A Dis REPL — a shell for writing Dis programs interactively.** Requested
   directly; this is a usability item, not a numerics one, and shares nothing
   with 1-7 except the VM.

   **Most of the machinery already exists, and it works.** Verified end to end
   before writing this:

   - `limbo -S` emits Dis assembly — instructions plus `desc`/`var`/`string`/
     `module`/`link`/`ldts`/`ext` directives.
   - `appl/cmd/asm/` is a **complete Dis assembler** with a yacc grammar
     (`asm.y`), and it still builds. It was simply **not in `appl/cmd/mkfile`'s
     `DIRS`**, so a command documented in `man/1/asm` had never been built.
     Fixed.
   - `disdump(1)` (`appl/cmd/disdump.b`) disassembles, and is built.
   - `dis(2)` reads Dis object files from Limbo.
   - `loader(2)` **builds and links a module in memory at runtime** —
     `newmod`/`tnew`/`ext`/`link`/`compile` take an array of `Loader->Inst` and
     produce a callable module, `compile` running the JIT over it.

   The round trip run to check this: a three-line Limbo program through
   `limbo -S`, then `asm`, then executed — printing its output — then
   `disdump`ed back to the same instructions.

   So the item is **not "write a Dis interpreter"**. Dis is already
   interpreted, JITted, assembled and disassembled here. The item is the
   interactive loop and the state that has to survive between lines.

   **The one hard problem is state.** Each `.dis` is a module with its own
   frame; typing `addw $1,$2,40(fp)` at a prompt only means something if `fp`
   persists to the next line, and Dis is a *typed* VM — every frame and data
   block needs a type descriptor so the garbage collector knows which words are
   pointers. A REPL cannot invent a frame layout as it goes without also
   maintaining that descriptor.

   Two approaches, and the cheap one should come first:

   a. **Accumulate and re-run.** Keep every line the user has typed, re-emit
      the whole session as one assembly file, assemble with `asm`, run it,
      show what changed. No VM work at all and it reuses `asm` verbatim.
      Quadratic in session length, which at typing speed does not matter, and
      state is *reconstructed* rather than live — so a line with a side effect
      outside the VM (a write to a file, a `print`) repeats every time. That
      limitation is the reason to do (b) eventually, and it should be stated
      to the user rather than hidden.
   b. **A live frame through `loader(2)`.** One module with a generously sized
      frame and a descriptor covering it, instructions appended as they are
      typed, `compile` re-run, execution resumed at the new code. State is
      genuinely live and side effects happen once. The work is in growing the
      frame and its descriptor without invalidating pointers the collector is
      tracking.

   Either way the REPL needs, beyond the loop: a way to show the frame and
   module data as words with their descriptor's pointer map applied (nothing
   does this today — `disdump` shows code, not data); `desc` declaration from
   the prompt, which `asm`'s grammar already accepts; and an error path that
   reports an assembly error without discarding the session.

   Sequencing: build (a) as `appl/cmd/disrepl.b` with a `man/1/disrepl` page,
   since it is a few hundred lines of glue over tools that already work; use it
   to find out what inspection commands are actually wanted; then decide
   whether (b) is worth the descriptor work. Do **not** start with (b).

   **(a) is built.** `disrepl(1)`. Four things it turned up that were not
   obvious from reading:

   - **`asm` resolved an undefined label to zero, silently.** A branch to a
     misspelled or dropped label became a branch to the first instruction of
     the module — a program that restarts forever, with nothing reported. Fixed
     in `appl/cmd/asm/asm.b`: a symbol now records whether it was ever defined
     as a label, and a destination referring to an undefined one is a
     diagnostic. Forward references within a file still work, because the flag
     is set in the pass that assigns program counters and checked in the pass
     that emits.
   - **The `$label` form is still silently wrong and cannot easily be fixed.**
     `bnew ...,$top` assembles: the dollar form is an expression evaluated as it
     is parsed, so the identifier is worth zero and the branch goes to
     instruction zero. Only the bare form carries a symbol as far as the fixup.
     Diagnosing it would mean rejecting identifiers in constant expressions
     generally, which has other uses. Documented in `man/1/asm` BUGS instead.
     This was the first loop written here, and it hung for two minutes.
   - **The host interrupt is not usable.** On this platform emu wires SIGINT to
     `cleanexit` (`emu/MacOSX/os.c`), so the usual interrupt character takes
     the whole emulator down and the session with it. Stopping a running
     program therefore has to be a line of input — `!` — arriving on the same
     channel as everything else and selected against the running program in one
     `alt`, with a time limit as a third arm for when nobody is watching.
     Input that arrives during a run and is *not* the interrupt is queued, or a
     piped session mistakes its own next command for one.
   - **A blocked process keeps emu alive.** Each run spawned a watchdog that
     blocked forever on a send nobody would receive, one per line typed.
     Nothing looked wrong until the session ended, at which point it hung for
     as long as the outer timeout allowed. Buffered channels for anything a
     losing racer has to send on, and kill the watchdog when it is not the arm
     that fired.
   - **`rread` printed a diagnostic for every interrupted read** (added in
     `003f169c`), and killing a process blocked in a read is the ordinary way
     to shut a reader down, so the console filled with it. Now suppressed for
     `Eintr` only, the way `devssl.c` already did.

   (b) remains undone and the argument for it is unchanged.

---

## Item 6 in detail: host-capability devices — `ml(3)`, video, and the shape

The goal is to reach the host OS's real capabilities — ANE, VideoToolbox,
AVFoundation, the camera, Metal — from Limbo. **None of this exists yet.** What
follows is the shape, because getting that wrong is what would make each new
capability a fresh one-off instead of an instance of one pattern.

### `gpu(3)`'s shape is right for what it does and does not generalise

`gpu(3)` is a synchronous RPC on a single file: write a request, read its
reply, one at a time. That is correct for *compute `y = Ax` and hand it back*,
and the parts of it that were paid for in blood should be kept —
binary wire format (text exhausted the heap at a 16³ matrix), nullable hooks so
the portable file has no platform `#ifdef`, a handle table of pointers resolved
under one lock (the array-of-structs version was a use-after-free), and a
precision request that reports what the device will *actually deliver*.

But three properties make it the wrong template for everything else:

1. **It cannot stream.** One request, one reply, cannot express "keep producing
   frames at 30fps".
2. **It cannot decouple producer from consumer.** The calling proc blocks for
   the whole operation, so no other proc can be draining results — which is
   precisely the shape Limbo is good at and Inferno is built for.
3. **Bulk data crosses on every call.** For a vector that is merely the
   bottleneck item 2 measures. For video it is fatal: a 4K frame is about 12MB,
   so 30fps is ~360MB/s through `memmove` and the pool allocator — which is
   exactly the path open bug 5 shows is unsafe under concurrency.

### The shape: one device per capability, composed through the namespace

Two conventions, both already in this tree.

**Clone plus numbered directory** (`ssl(3)`, `ip(3)`), not the flat single file
`gpu(3)` borrowed from `audio(3)`. Flat is right when there is exactly one
instance; these have many concurrent ones. So `/dev/video/clone` giving
`/dev/video/N/…`, and likewise for `ml`.

**Separate `ctl` and `data`** (`audio(3)`: `/dev/audio` + `/dev/audioctl`),
which is also what streaming needs — one proc writing while another reads,
instead of a lockstep round trip. This does *not* contradict `gpu(3)`'s "text
was too slow": that was about payload. Text is right for control and wrong for
bulk, and the two-file split is what lets each be what it should be. `ctl`
takes a verb-per-line command language, which is this tree's established idiom
already — `tk(2)`, `krylov(2)`, `pde(2)`, `gpu(2)` all work that way.

**And that is the whole mechanism. Do not add a second one.**

A registry of host-resident objects addressed by integer id was built here and
**reverted**, because it was wrong in a way worth recording so it is not
rebuilt. The argument for it was real — capabilities need to pass large things
between them without copying through the Limbo heap — but the design answered
it by exposing the *host's* structure (a handle table over `CVPixelBuffer`s)
instead of virtualising the *capability*. Three things that breaks:

- **Inferno already has the shared handle space: the namespace.** `Chan`s and
  file descriptors are the capability handles. A parallel id space reinvents
  them, worse.
- **It breaks distribution.** Styx exports file trees, so `/dev/video/0/data`
  can be mounted from another machine and used exactly like a local one.
  "Object 79 in a local registry" cannot be exported at all — the design
  quietly makes every capability local-only, which is the opposite of the point.
- **It breaks the security model.** Per-process namespaces *are* how authority
  is restricted here. A global id table is ambient authority: any proc that can
  open the control file can name any object, whatever its namespace says.

So: **one device per capability, each presenting what it does in Inferno's
terms**, and composition through the namespace — read from one, write to
another; bind; mount; export over Styx. A `CVPixelBuffer` is host structure. "A
stream of frames you can read" is a capability.

### Then what about the copying, which was a real problem?

Three honest answers, in preference order, none of which needs a new namespace:

1. **Reuse the namespace that already exists** — and for video this is not a
   fallback but the answer: put decode *in* `draw(3)`, where images already
   have connection-scoped names and where a coherence protocol for host-side
   pixels already exists. See "Movies belong in draw(3)" below.
2. **Keep the capability on one side of the boundary.** If decode and display
   never need to be separated, they need not cross at all.
3. **Do the optimisation invisibly.** If two host-backed devices are connected,
   emu may shortcut between them internally. That is an implementation detail
   behind the file interface, which is where it belongs — not a namespace
   feature. The interface stays "read frames"; whether a copy happened is the
   kernel's business.

And the caveat stands regardless of mechanism: Limbo programs must still be
able to *get* the pixels, because processing them is what `videosynth.b` and
the Dream Machine work do. Reading `data` gives you the bytes; that path must
stay, and its cost should be visible rather than surprising.

### Lessons from the reverted attempt that apply to whatever is built next

Three things it got right or learned the hard way, all of which transfer:

- **Enumerate by a stable slot, not by position in a snapshot.** `devwalk`
  resolves a name by calling the gen function with successive indices, so if
  index *i* means "the i'th live thing", concurrent creation and destruction
  move the answer and a walk can step straight past something that existed the
  whole time. This was a real bug, found by a test, not by inspection.
- **A pending `ctl` reply belongs to the open, not to the device.** One global
  reply has concurrent clients overwriting each other's answers. `devgpu.c`
  already does it per-handle for this reason.
- **Hold one `ctl` fd per client rather than opening per command.** The first
  version of that test opened `ctl` twice per operation and spent eight runs in
  twelve inside the scheduler hang of open bug 1 — it was measuring that bug,
  not the device. Fewer opens took it to one in twelve.

### Movies belong in `draw(3)`

Not a separate `/dev/video`. A decoded frame **is an image**, `draw(3)` already
owns images, and putting decode there is what makes zero copy reachable rather
than aspirational. Three things in the existing code say this fits rather than
being bolted on:

- **Draw images already have names, scoped the right way.** Image ids are per
  draw connection (`/dev/draw/N`), so they live inside the caller's namespace
  and inherit its authority — which is exactly what the reverted global id
  table did not.
- **A texture cache keyed by `Memimage*` already exists.** `win-cocoa.m` keeps
  one for sprites (`sprtexcache`), uploading with
  `replaceRegion:mipmapLevel:withBytes:`. "A draw image whose pixels live on
  the host" is therefore already half-present; video changes only *who fills
  the texture*.
- **The coherence protocol already exists.** `devdraw.c`'s read case calls
  `gpudrawreadback()` before handing pixels back — *"A read observes all
  preceding draw3d work, including GPU queues."* Host-side pixels that must
  materialise on demand is a solved problem here, and a video frame is the same
  category as GPU-drawn content, not a new one.

**The chain.** AVFoundation demuxes; VideoToolbox decodes to a `CVPixelBuffer`
backed by an `IOSurface`; `CVMetalTextureCache` turns that into an `MTLTexture`
with no copy; `win-cocoa.m` composites `MTLTexture`s already. So decode to
display touches no Limbo memory and performs no `memmove` at all.

**The Limbo-visible interface is just an image plus a control verb** — allocate
an image as usual, then tell draw to play a source into it. No new namespace,
no new object space, and the frame is addressed the way every other image is.

**Distribution still works, which is the test of whether the layering is
right.** A remote client reading that image over Styx goes through draw's
ordinary read path, `gpudrawreadback()` materialises the pixels, and it sees a
normal image. Zero copy is a *local* optimisation; correctness does not depend
on it. That is the property the reverted design destroyed.

Costs and risks, none of them hidden:

- **`bdata` goes stale.** While a frame lives only in a texture, the
  `Memimage`'s own pixels are not current. Reads are covered by the existing
  readback, but every *memdraw* path that touches such an image must either
  force a readback first or be refused. That is the one genuinely invasive
  part, and it is where this will go wrong if rushed.
- **Readback is not free**, so a Limbo program processing frames — which is
  what `videosynth.b` and the Dream Machine work do — pays real cost per frame.
  It must stay possible and it must be obvious, not silently expensive.
- **A/V sync and backpressure** against `audio(3)`: presentation timestamps,
  and a read that blocks until a frame is ready.
- Only `emu-cocoa` has any of this; `emu-g` must keep working with the hooks
  nil, as it does for `gpu(3)` and the existing draw hooks.

**A useful side effect.** Ordinary images are uploaded to Metal today with
`replaceRegion:withBytes:` — a CPU copy per image. The texture-backed-image
work video needs is the same work that would remove that copy, so the two wants
are one piece of work rather than two.

**Built so far** (`845e8f40`, `09321675`): texture-backed draw images behind
`INFERNO_TEXIMAGE`, where an image's pixels are allocated from Metal so bdata
and a texture are the same bytes; and `/dev/draw/N/video`, whose
`decode <id> <path>` runs the platform's hardware decoder into an ordinary
draw image. `drawdecodetest(1)` covers both, deliberately at a width whose
natural stride differs from the aligned one so that a wrong `width` or `zero`
would show. Two things learned doing it, both now settled the right way: the
decode hook takes encoded **bytes**, not a path, because a path would have to
be a host path and would punch through the namespace - the first version did
exactly that and failed on an ordinary Inferno path; and only 32-bit images
can be texture-backed, so on a typical workload most images still come from
the pool.

Movies decode too (`65a67fcc`), and stream (`this commit`): `open`/`next`/
`close` on the same file run a decode session, so playback is one pass instead
of re-reading per frame - 4ms against 65ms for ten frames of the test clip -
with the encoded stream pushed in chunks so memory stays bounded. The fixture
and its generator are both in the tree (`lib/movies/test.mov`,
`emu/MacOSX/mkmovie.m`), flat colour per frame so a decode test can assert a
colour rather than "something was written".

**Streaming is done** (`45be0862`): `quicktime(2)` locates samples in Limbo,
`decoder`/`target` on `/dev/draw/N/video` configure a VideoToolbox decoder from
the `avcC` parameter sets, and each write to `/dev/draw/N/videodata` is one
coded sample. Nothing staged, nothing read ahead, memory flat in the length of
the movie. `vstreamtest(1)` drives it.

**Zero copy is not worth doing yet, and this is measured.** The remaining CPU
copy is the decoder's pixel buffer into the image's `bdata`. At 1080p:

| | |
|---|---|
| decode, 60 frames of 1920×1080 | 140ms, i.e. **2.3ms/frame (~430fps)** |
| the copy itself | 7.9MB/frame, ~0.15–0.4ms at realistic bandwidth |

So the copy is **6–17%** of a path already running about ten times faster than
real-time playback needs, and removing it requires the `bdata`-staleness rule —
the most invasive change on this list, touching every memdraw path that might
read a texture-backed image. **Do not do it for speed.** The case for it is
4K, high frame rates, or several streams at once, and that case should be
measured before the work, not assumed.

The better-targeted win, if decode throughput ever matters, is that each sample
is decoded synchronously with a wait: pipelining would help more than deleting
the copy.

**Audio decodes too** (`a4792b59`). `/dev/audiodec` is a *filter*: write one
coded sample, read back its PCM, configured by `decoder <codec> <rate>
<channels> <hex setup>` on `audioctl`. Same split as video — `quicktime(2)`
finds the samples in Limbo, only the coded bytes cross. A filter rather than a
sink because that composes, and because a sink cannot be tested without
listening to it: `adectest(1)` measures the *pitch* of the decoded PCM against
the tone the clip was built with (220Hz in, 216Hz back).

So both halves of a movie now decode, and **`playmovie(1)` now synchronises
them**. The audio is the clock: a write to `/dev/audio` blocks when the device's
buffer is full, so feeding it paces the loop for free and gives a position to
fit the video to. Driving the other way — frames on a timer, audio resampled to
match — is audible. The clock reports what has been *handed to* the device
rather than what has been heard, but that offset is constant: it shifts the
whole picture, it does not accumulate.

Two things came out of building it that are worth keeping.

**Frames cannot be paced in decode order.** The first version fed each sample as
`quicktime(2)` reported it and compared its presentation time against the clock.
That is wrong for any stream with B-frames, and wrongly by a lot: it put frames
up to **317ms** from where they belong on `av.mov`. Presentation order needs
several decoded frames alive at once, so `playmovie` decodes into a ring of four
draw images and shows the earliest held frame the clock has reached — **19ms**,
which is under one AAC packet (23.2ms) and therefore the clock's own
granularity. Setting the ring to one restores 317ms exactly, which is the
negative control. The ring can in principle be too small for a stream's
reordering depth; that shows up as a frame that would have to be shown after a
later one, and is reported rather than passing quietly.

**A short clip does not exercise pacing at all.** `av.mov` is 1.07s, fits
entirely in the audio device's buffer, never blocks, and finishes in 0.9s — so
the first "it plays" was not evidence of anything. An 80-frame clip from
`mkmovie` plays in **8.01s for 8s of audio** with the error still at 22ms, i.e.
bounded rather than growing over 8× the length. That is the measurement that
means something.

Building that longer clip needed a fix to `mkmovie` itself. It appended all the
video and then all the audio, which survives ten frames and throws
`readyForMoreMediaData is NO` at eighty: `AVAssetWriter` will not take an
unbounded backlog on one input while another is starved. It now interleaves by
presentation time, feeding whichever input is furthest behind, which has no such
limit.

To reproduce the measurement, generate a larger clip rather than committing one
— `mkmovie` takes a size: `./mkmovie /tmp/big.mov 1920 1080 60`, then
`vstreamtest /tmp/big.mov`. Only the small committed fixture is checked pixel
by pixel; on any other clip `vstreamtest` skips the readback, because reading a
1080p image back through the draw protocol would measure the test rather than
the decoder.

`quicktime(2)` **now does the parsing half** (`720e32cb`). It was a header
parser only — an earlier version of this note claimed otherwise without
checking — and now has real sample tables: `tracks()` returns each track's
codec, timescale, dimensions, the verbatim codec setup data (`avcC` for
H.264), and every sample's offset, size, duration and sync flag. Verified by
`qttest(1)` against `lib/movies/test.mov`, whose contents are known exactly
because `mkmovie.m` wrote them.

That is deliberate placement: **finding samples in a container is a
data-format job and belongs in Limbo**; the device's capability is decoding
H.264 samples, which is the part only the hardware can do.

So what is left for streaming is now only the device half: a
`VTDecompressionSession` configured from the `avcC` parameter sets, and a way
to hand it one sample at a time. The text `ctl` cannot carry binary samples,
so that wants a second file in the client directory — the same `ctl`/`data`
split applied one level down. Then `CVMetalTextureCache` so the
decoder's pixel buffer *is* the image's backing rather than being copied into
it; presentation timestamps and A/V sync against `audio(3)`; and the
`bdata`-staleness rule for memdraw paths, which remains the genuinely invasive
part.

**What exists to build on, and what does not.** `appl/wm/avi.b` decodes in
Limbo and pushes pixels into a `Draw->Image`; `appl/wm/mpeg.b` and
`appl/wm/qt.b` are commented out of `appl/wm/mkfile` and do not build. And per
the measured table above, the formats those decoders handle are precisely the
ones with **no** hardware support. So this is not "accelerate the existing
players" — it is playing formats the tree currently cannot play at all.

### `ml(3)` is then just another instance — and it is now built

Same clone directory, same `ctl`/`data` split: `/dev/ml/N`, where `ctl` selects
the model and compute units, `in` takes the input and `out` gives the result.
The instance *is* the handle — no ids, so a model can be used across a Styx
mount like anything else. `emu/port/devml.c` owns the protocol,
`emu/MacOSX/win-ml.m` is CoreML behind the same nullable hooks `devgpu.c` uses,
and `mltest(1)` runs it end to end. It works under `emu-cocoa` and headless
under `emu-g`.

**The two hard questions were settled by measurement, not by choosing.**
`emu/MacOSX/mlcaps.m` — a standalone probe, deliberately not part of the build,
the same shape as `vtcaps.m` — was written and run *before* the protocol, and
both answers came out better than the plan assumed:

- **The model crosses as bytes, and there is no namespace puncture at all.**
  The plan posed this as a fork — pass host path bytes and accept the puncture,
  or stage. It is not a fork: `compileModelAtURL:` accepts a *staged single-file*
  `.mlmodel` and produces the compiled `.mlmodelc` itself, so only bytes ever
  cross and no `.mlmodelc` directory has to be moved anywhere.
- **The compute unit actually used can be reported honestly.** `MLComputePlan`
  (macOS 14.4+) gives a device per operation, so `info`'s `device` line says
  what ran rather than what was asked for. This is exactly where `gpu(3)`
  shipped the bug once, and it is *verified* rather than assumed: `units cpu`
  reports `cpu` while the default reports `ane`, so the line cannot be a
  constant string. That check is in `mltest(1)`.

Two things the plan did not anticipate, both of which would produce a
plausible wrong answer rather than an error:

- **The element type is not f32.** The fixture model declares **f64**, and
  CoreML publishes the type per feature. A client that assumed f32 would write
  exactly half the bytes needed. `info` therefore carries type and shape, and a
  mismatched write is refused with an error naming both sizes.
- **Byte order has to be decided and stated.** The wire is big-endian, matching
  `gpu(3)` and what `math(2)`'s `export_real` already produces, so a Limbo
  caller marshals with what it has and a model reached over a Styx mount from a
  different-endian machine still gets what was meant. The host wants native
  order, so the swap lives in the backend, which is the end that knows the
  element type. The negative control: feeding native-order bytes yields
  `(0.5, -0.5)` — the bias term alone — instead of `(14.5, 139.5)`.

The fixture is `lib/ml/linear.mlmodel`, built by `emu/MacOSX/mkmlmodel.py` with
weights chosen by hand rather than trained, so the answer is known: `W =
[[1,2,3],[10,20,30]]`, `b = [0.5,-0.5]`, `x = (1,2,3)` gives `y = (14.5,
139.5)`. The two outputs differ by an order of magnitude and neither is
symmetric in its inputs, so a transposed matrix, a swapped output, a wrong
element width and a byte-order mistake each show up as a visibly wrong number.
Note `coremltools` is needed only to *build* the fixture, and only in a venv —
it is not a dependency of the tree or of the test.

Two concurrency bugs were found by review after it worked and fixed before the
next commit, both worth recording because the passing test could not have
caught either. `Sys_write` and `Sys_read` **release the VM** around the device
call (`emu/port/inferno.c`), so two Limbo processes really can be inside
`devml` at once — which means (a) the read and close paths had to take the same
qlock the write path already took, or `run`'s `free(m->out)` races a reader and
`reset`'s `mlclosemodel` races an `info`; and (b) the qid could not name the
instance by *slot*, because slots are reused and `in`/`out` fds are allowed to
outlive their `ctl` fd — so a stale fd resolved to whoever took the slot next.
The instance id now lives in `qid.vers`. The control for that second one is
worth keeping in mind: with the check removed the stale write did **not**
obviously fail, it reached the new instance and returned *that* instance's
error, so the discriminator is which error comes back, not whether one does.
The same release-the-VM fact means the long CoreML calls do not freeze other
processes — checked rather than assumed.

Say plainly what this device is not: CoreML runs a compiled model graph and the
ANE has no public API outside it, so `ml(3)` will not accelerate a CG solve or a
stencil sweep. It is worth having for inference, not for the numerics. Only
multi-array features are handled; anything else reports as `opaque` in `info`
and cannot be fed.

### What this means for the rest of the plan

Item 2 (device-resident vectors) wants the same *property* — a big thing that
stays put while only small things cross — but it does **not** want a shared id
space either, for the reasons above. `gpu(3)` already keeps its matrix resident
against an open handle, and vectors should live against that same handle: the
`Chan` is the name. That keeps it exportable over Styx and inside the caller's
namespace, which an id table would not.

Sequencing: the registry and the clone/`ctl`/`data` shape first, since
everything else is an instance; then whichever capability is actually wanted.
None of it blocks items 1–5, and none of it should be allowed to delay them.

## Item 7 in detail: vector instructions in Dis and the JIT

Three separate questions get conflated here, and keeping them apart is most of the design: what a Limbo programmer writes, what Dis represents, and what the JIT emits. **The third can be answered without touching the first two, and that is where to start.**

> **Provenance:** this section was contributed as a design note, not derived
> from measurements taken here. Its factual claims about this tree were checked
> and hold (`FPsave`/`FPrestore` really do save only `FPSR`/`FPCR`; `math(2)`
> really is a C builtin; `WORD` really is `intptr`; the `comp-arm64.c` refcount
> gap really is the one `dis.c` documents), and its cited timings match item 2
> above. The one number **not** verified here is the "roughly six Dis dispatches
> per element" estimate — plausible from the opcode sequence, but nobody has
> counted it in this tree. Measure it before using it to justify the work.

### Start with builtin module functions, not new opcodes

`math(2)` is already a builtin implemented in C (`libinterp/math.c`). Adding `math->dot`/`axpy`/`norm`/`scale`, or a `blas(2)` alongside it, costs no Dis change, no JIT change, no spec change and no compiler change. The C implementation gets auto-vectorised by clang, or calls Accelerate/vDSP — which is also the **only** way to reach AMX, since it has no public API.

The reason this captures most of the value is dispatch, not arithmetic. `for(i=0;i<n;i++) s += x[i]*y[i]` pays roughly six Dis dispatches per element — two `IINDF`, each with a bounds check, plus `IMULF`, `IADDF`, increment and compare. A builtin pays one `mcall` for the whole array and one length check. That is an order of magnitude before any SIMD, and SIMD multiplies on top of it.

This targets exactly what is measured in item 2 above: at 30³ the CG loop's `dot`/`axpy`/`norm` are 16ms of 39ms once matvec is offloaded, and CPU `sparse->matvec` is 110ms. Those are BLAS-1 and BLAS-2 shapes. They want library calls, not new instructions.

### If Dis is extended, the unit is an array, not a lane

Width-agnostic aggregate opcodes (`IVADDF`, `IVDOT`, `IVAXPY` over whole `array of real` operands), **never** fixed-width lane types like `real4`. Fixed widths leak the architecture into both the language and the bytecode — 128-bit NEON, 256/512-bit AVX, scalable SVE. Dis has stayed portable for thirty years by being width-agnostic, and `doc/dis.ms` is a real spec this tree treats as authoritative: read its stance on extension before adding anything (that lesson cost real time once already — see the `newa` entry under Gotchas).

Aggregate ops also amortise the bounds check to one per instruction, which is a large part of the win independent of SIMD.

### Auto-vectorising existing Dis in the JIT is the last resort

Pattern-matching loops in `comp-arm64.c` needs loop recognition, alias analysis, bounds-check elimination and trip-count invariance — a serious compiler project against bytecode not designed to make it easy, with per-element frame accesses and explicit bounds checks in the way. Low payoff against either option above.

### Traps specific to this tree

- **`WORD` is `intptr`, so 64-bit here.** `array of int` has 64-bit elements: two NEON lanes, not four. `libinterp/math.c`'s `export_int` bug — casting Limbo array data to C `int*` — is exactly this class of mistake, and it is fixed but instructive. No vector builtin over `array of int` may assume 32-bit lanes.
- **The interpreter stays authoritative.** `-c0` and `-c1` must agree; the JIT is an optimisation, not a semantics provider. Every new opcode needs an `xec.c` implementation *and* one in every `comp-*.c`, or `.dis` files stop being portable.
- **Reduction reassociation breaks reproducibility.** A vectorised `dot`/`norm` reassociates floating-point addition, so `-c0` and `-c1` would disagree numerically. That would undermine `verify(2)`'s convergence-order study and any negative control. This session already saw f32-vs-f64 shift CG iteration counts 22→25 and 42→52; the same sensitivity applies. Either fix the reduction order in the spec or document the divergence explicitly.
- **FP register state across scheduler switches.** `emu/MacOSX/asm-arm64.s`'s `FPsave`/`FPrestore` save only `FPSR`/`FPCR`, relying on the C ABI for the register file. On AArch64 only the **low 64 bits** of `v8`–`v15` are callee-saved. If the JIT holds live vector values there across a point where `release()`/`acquire()` can run, that is silent corruption.
- **Restrict to pointer-free element types** (`byte`, `int`, `big`, `real`). That sidesteps GC pointer maps and write barriers entirely, and is a clean defensible boundary.
- **`comp-arm64.c` still has the unfixed non-atomic refcount gap** (see `dis.c`'s GC-LOCK HISTORY comment). Work in that file should either close it first or take care not to make it worse.

### Sequencing

Builtins first — they are the existing mechanism and capture the dispatch win. Measure against the CG loop; the numbers to beat are already recorded in item 2. Only if that proves insufficient does aggregate-opcode work become justified, and by then there will be real data on which operations matter.

---

## Open bugs

### 1. Scheduler deadlock under concurrent fd use — **FIXED**

**`unlock()` had no release barrier, on any platform, ever.**

```c
void
unlock(Lock *l)
{
	coherencefn();
	l->val = 0;
}
```

`coherencefn` is a function pointer that starts nil and is set exactly once, in
`main()`, to `nofence` — an **empty function**. Nothing in the tree assigns it
anything else, on any platform. So `unlock()` was a plain store with nothing in
front of it.

On x86 that is nearly harmless: its store order is already what this code
assumes. On arm64 it is not. The stores a critical section makes can become
visible *after* the store that releases the lock, so the next thread to take
the lock — whose `_tas` does have acquire semantics (`ldaxr`/`stlxr`) — can read
state the previous holder finished writing but had not yet published. A proc
pushed onto `isched.vmq` could therefore vanish from the queue with nobody
popping it, which is precisely the symptom this section spent so long
characterising.

The fix is one line: make the release a release.

```c
	__atomic_store_n(&l->val, 0, __ATOMIC_RELEASE);
```

`emu/port/alloc.c` already uses `__atomic_store_n(..., __ATOMIC_RELEASE)`, so
this is the tree's own idiom rather than a new dependency.

The whole bug and the whole fix, one instruction, read out of the two binaries
rather than assumed from the source:

```
baseline   blr x8            ; coherencefn - nofence, does nothing
           str  wzr, [x19]   ; plain store

fixed      blr x8
           stlr wzr, [x19]   ; store-release
```

**Measured, interleaved, alternating binaries in one session** — the validation
this section demanded, and which the earlier `vmqnext` candidate failed:

| reproducer | baseline | fixed |
|---|---|---|
| `fdstresstest`, `-c1`, 150 pairs | 81 pass / **67 hang** / 2 other | **150 pass / 0 hang** |
| `fdstresstest`, `-c0`, 80 pairs | 54 ok / **26 hang** | **80 ok / 0 hang** |
| `gputest`, 25 pairs | 11 pass / **8 hang** / **6 other** | **25 pass / 0 hang / 0 other** |

Note `gputest`'s *other* column: six crashes on the baseline, none with the fix.
Those included `panic: decref` (bug 6). That is an observation, not a claim that
bugs 5 and 6 are fixed — nobody has run their own reproducers against this — but
anything that reads a torn view of memory another thread was midway through
publishing is a good candidate for both, and they should be re-measured before
any further work is done on them.

Cost: **1-2%**, at the noise floor of a five-second `pde(2)` run (5.02/5.15s
baseline against 5.12/5.17s fixed). `gpubench` appears to show 20% but does not:
that is one millisecond of clock quantisation on a six-millisecond solve.

**Still true and still not fixed**: `coherencefn` remains `nofence`. `unlock()`
no longer depends on it, but `emu/port/win-x11a.c:628` still calls it and still
gets nothing. That is a latent bug for an X11 build, which cannot be tested
here.

**"Bug 1 fixed" is not "the lock has been audited".** Only the release side was
wrong and only the release side was changed. The acquire side was read and left
alone: `_tas` is `ldaxr`/`stlxr`, which is correct, but each failed attempt in
`lock()`'s spin abandons the exclusive monitor without `clrex` — flagged as
step 3 in the original analysis below and still not examined. It is not
implicated by any evidence here; it is simply the part nobody has looked at.

**How it was found**, since three earlier attempts were not:

1. The plan's step 2 — audit every `isched.vmq`/`vmqt` access for one outside
   `isched.l` — found nothing. All four sites are locked and the unlocked reads
   are all re-checked before acting.
2. Step 1's instrumentation said `vmq_badtail == 0` over 4923 pushes: the tail
   was *always* reachable at a push, killing the "linked onto a stale tail"
   half of the hypothesis outright.
3. Per-proc history (a ring was useless — 10000 events over 128 slots, the
   stuck proc's push long overwritten) showed the stuck proc with
   `dbgpush=413 > dbgpop=389`: pushed, never popped, yet `isched.vmq == nil`.
4. A direct invariant — maintain a count of pushes minus pops, walk the list
   under the lock, compare — caught the list going from length 2 to length 1
   **between two consecutive locked operations, with no pop in between**. At
   that point the only remaining possibilities were "the lock does not
   exclude" or "something else writes the links", and the lock was where the
   plan's own step 3 said to look.

The instrumentation moved the hang rate from ~40% to ~5% when the walk was
under the lock, exactly as this document warns elsewhere. It still reproduced,
so it still worked; the rate is a timing artefact, not evidence.

### Original analysis, kept because the method is worth reading

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

**Build dependencies are declared per directory, and a missing one is silent.**
Two instances, both of which cost real time:

- A Limbo directory's `mkfile` lists the `module/*.m` files it depends on in
  `SYSMODULES`. `appl/lib/mkfile` had `quicktime.m`; `appl/cmd/mkfile` did not.
  So changing `module/quicktime.m` rebuilt the library and **not** the commands,
  and they drifted apart until a program died with
  `link typecheck QuickTime->tracks() db7bb871/101c27d5`. If a new module is
  used from a directory, add it to that directory's `SYSMODULES` — the rule in
  `mkfiles/mkdis` (`%.dis: $MODULES $SYS_MODULE`) is already there and does
  nothing without the list.
- `emu/MacOSX/mkfile` has an **empty `HFILES`**, so editing `emu/port/dat.h`
  does *not* trigger a rebuild — you can silently get a
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

**It is the Metal compute path, and that is now measured, not guessed.**
`INFERNO_NOGPUHW=1` (added for this, `emu/MacOSX/win-gpu.m`, documented in
`gpu(3)`) leaves the hardware hooks unregistered so `gpu(3)` uses its own C
loop. Same binary, same Cocoa environment, only the backend differs —
`gputest`, poison on, 10 runs each:

| Metal | passed | failed | poison reports |
|---|---|---|---|
| on | 1 | 9 | 1 |
| **off** | **8** | **2** | **0** |

The corruption follows the backend. (The residual 2 of 10 is the scheduler
hang of open bug 1, which is present either way.)

That does **not** mean the bug is necessarily *in* `win-gpu.m`'s own code. The
structural fact worth knowing is that this emu links with
`-Wl,-alias,___wrap_malloc,_malloc` and friends, so **every `malloc` and `free`
in the whole process — Metal's, Foundation's, the Objective-C runtime's — goes
through emu's pool allocator**, from threads that are not emu procs. Turning
Metal on turns that traffic on. Two things already checked, so as not to repeat
them: emu's `lock()` is safe on a foreign thread (`osyield`/`osmillisleep`
never touch `up`), and `poolfault` — which panics loudly when a pointer that is
not an emu block is freed into the pool — never fires, which argues against the
simplest "allocated by one allocator, freed by another" story.

**What the write is.** `Sys_read` (`emu/port/inferno.c`) does:

```c
release();
*f->ret = kread(fdchk(f->fd), f->buf->data, n);
acquire();
```

— it hands the Limbo array's raw `data` pointer to the host read *after*
releasing the VM, and `gpuread` finishes with
`memmove(va, g->resp + g->respoff, m)` where `va` **is** that pointer. So the
corruption is the device writing a reply into a destination buffer that has
been freed during the released window. That matches the captured bytes exactly:
what lands in the free block is always a matvec reply, never anything else.

Why Metal matters is then not that Metal is buggy, but that `metal_spmv` does
`[cb waitUntilCompleted]` — roughly 0.3ms with the VM released, against
microseconds for the C loop. It widens the window enormously.

**Hypotheses tested and refuted — do not repeat these:**

| # | hypothesis | how it died |
|---|---|---|
| 1 | JIT non-atomic refcounts (`-c1` only) | `-c0` corrupts identically: 0/10 vs 2/10 passes |
| 2 | slice temporary (`rbuf[off:]`) collected mid-call | rewritten with no slice: 1/10 either way |
| 3 | foreign allocator frees into emu's pool | `poolfault` panics on exactly that and never fires |
| 4 | two threads inside the pool's locked region | per-pool entry counter: **0 violations in 15 runs** |
| 5 | heap compaction moving the block | `poolsetcompact` is never called anywhere; `p->move` is always nil, so `poolcompact` returns immediately |
| 6 | `killprog` tearing down a stack mid-syscall | its `Prelease` case sets `Pexiting` and returns without destroying the stack |
| 7 | attribute the block via `allocpc` | resolves inside `__wrap_malloc` itself — `getcallerpc` does not return the caller here, so the field is useless on this platform |

Four and five are the important ones: **the allocator itself is behaving.**
Mutual exclusion holds and blocks never move, so the block really is being
freed and then written by someone still holding its address.

**The free side was instrumented and the answer is "not observed".**
`poolinflight()` (`emu/port/alloc.c`, same `INFERNO_POOLPOISON` flag) registers
a syscall's buffer for the duration of its released window, and `poolfree`
reports if the block it is about to free contains one. Across 30 runs it never
fired.

**Do not trust that negative.** In the same runs the corruption stopped being
detected at all: 0 `POOLPOISON` reports in 45 runs against a base rate near 1
in 10 (p ≈ 0.008), while the *failure* rate went the wrong way — 0 of 15
passing. So the bug is still there; the detectors stopped firing. The likely
reason is that `poisoncheck` only fires when a corrupted block is later removed
from the free tree, and these runs die sooner.

That is the **third** time instrumentation has moved this bug (after the
watchdog on `fdstresstest` and whole-block poisoning), and the second time it
was the added *synchronisation* specifically: the first version of the
in-flight check took a lock on every `poolfree` and suppressed the corruption
entirely. It is now lock-free for that reason, and the rule for anything on
this path is: **no locks, no allocation, no syscalls — a scan of a small array
is the budget.**

Where that leaves it. The proc is `Prelease` with a live frame, so the
destination array *should* be rooted, and nothing observed says who frees it.
Two things worth trying that do not add work to the free path: run the whole
thing under a build with `-fsanitize=address` (an `emu-cocoa-asan` binary
exists in this tree from earlier work, though there is no mkfile target for
it — note the `-Wl,-alias,___wrap_malloc` aliasing has to go for ASan to mean
anything); or make `poisoncheck` fire at the moment of corruption rather than
at the next `pooldel`, by having the *GC* verify poison across the whole free
tree at a safepoint, which costs nothing on the allocator's hot path. The cheaper first cut was tried and came back **inconclusive**, so it is
recorded rather than repeated blindly. A temporary 1ms sleep in `gpuwrite`'s
`X` handler, with `INFERNO_NOGPUHW=1` so no Metal was involved at all:

```
Metal off, no delay   pass 8  fail  2   poison reports 0   (of 10)
Metal off, 1ms delay  pass 2  fail 10   poison reports 0   (of 12)
Metal on              pass 1  fail  9   poison reports 1   (of 10)
```

The delay reproduces Metal's *failure rate* — but that is not the same as
reproducing the *corruption*, and it did not produce a single poison report.
Two reasons not to read it as confirmation: a 1ms sleep per matvec across 40
procs adds a great deal of blocking, so the extra failures are just as easily
the scheduler hang of open bug 1; and 0 reports in 12 runs is unremarkable
when the base rate is about 1 in 10. If this is retried, **classify the
failures** — hang versus crash versus poison report — because the undivided
pass/fail number cannot distinguish the two bugs, which is exactly the trap
that nearly cost the `gethandle` fix earlier.

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

**`emu-g` faulted once in the console keyboard slave**, at startup, and did not
reproduce in five further runs of the same command:

```
dopoolalloc -> kmalloc -> qproduce -> kbdslave -> tramp
SYS: process kbd faults: dereference of nil
```

Seen while running `disrepl` with piped stdin. Recorded because a one-off with
no note is indistinguishable from a fresh bug next time; it is *not* one of
bugs 1-6 above.


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

**A Limbo `int` is stored in 64 bits but arithmetic on it is 32-bit.** Both
halves matter and they are easy to conflate — an earlier version of this note
said simply "Limbo int is 64-bit here", which is wrong as stated.

*Storage*: `WORD` is `intptr`, so each element of an `array of int` occupies 8
bytes. `math->export_int`/`import_int` cast to C `int*` and so mangled every
multi-element array (`[1,2,3,4]` → `[1,2,0,0]`) until `1561fcaa`. **Anything
else casting Limbo array data to C `int*` has the same bug.**

*Arithmetic, and the trap*: an `int` here holds **more than 32 bits**, so it
does **not** wrap — `255<<24` really is 4278190080, not −16777216. But
`sys->print("%d")` formats only the **low 32 bits**, so that value *prints* as
−16777216 and `16rffffff88` prints as −120 while arithmetic on it uses
4294967176.

That combination is vicious: a value reads correctly, prints wrongly, and then
computes "wrongly" in a way that looks like the print. It cost real time here —
a `ctts` composition offset printed as −120, was assumed to be sign-extended
already, and produced a display index of 71582789. **Do not infer an int's
value from `%d`.** Print through `big` (`%bd`) when it might exceed 2^31.

Consequences: reading a 32-bit field gives the true *unsigned* value, so a
chunk offset in a file over 2GB is fine unmasked — but a genuinely *signed*
field must be sign-extended explicitly (see `bes32` in `appl/lib/quicktime.b`).
An earlier version of this note claimed the opposite, that arithmetic wraps at
32 bits; that was itself an artifact of believing `%d`.

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
