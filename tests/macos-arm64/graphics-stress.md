# Graphics stress test

Build and install:

    cd appl/wm
    mk gfxstress.dis install

Run the complete one-second-per-phase check with the JIT:

    MacOSX/arm64/bin/emu -c1 /dis/wm/gfxstress.dis all 1

Run one phase for a longer profile:

    MacOSX/arm64/bin/emu -c1 /dis/wm/gfxstress.dis alpha 10

The phases are `fill`, `copy`, `overlap`, `alpha`, `mask`, `line`,
`ellipse`, `thickellipse`, `poly`, `text`, `upload`, `damage`, `windowmove`, and
`draw3d`. Each phase prints its operation count, elapsed milliseconds, and
operations per second.

`thickellipse` is a regression test rather than a measurement, and the only
phase here that is an oracle: reaching its `GFXSTRESS` line is the check
passing. It draws at the four semithicknesses for which `memellipse`'s brush
disc was allocated too small, because `allocmemimage` computed `nw = l*Dy(r)`
in `u32` and a thickness past 2^32 words wrapped to a small one — at
`t=185352`, 83352 bytes for a rectangle holding 17.2 GB of pixels. Before the
guard it faults as `memimagedraw <- memdraw <- memellipse <- memellipse <-
drawmesg`; the two `memellipse` frames are the outer call and the brush disc's
own fill.

Note that `ellipse` already reaches that brushed path and always did: at `t=2`
with radii `5+rnd(40)` by `5+rnd(30)`, `2t(a-b) > b^2` holds for most draws, so
the brush disc is the common case there, not the exception. 7,339,500 ops of it
run clean on this host.

`draw3dthick` specifically stresses synchronized queue handoff and bounded
backpressure with thick GPU lines; it is also included in `all`.

Exercise clear-layer window movement and report actual Metal copy traffic:

    INFERNO_METAL_STATS=1 MacOSX/arm64/bin/emu -c1 /dis/wm/wm.dis /dis/wm/gfxstress.dis windowmove 5

Run it with synchronous byte-for-byte CPU/Metal softscreen validation:

    INFERNO_METAL_VALIDATE=1 MacOSX/arm64/bin/emu -c1 /dis/wm/wm.dis /dis/wm/gfxstress.dis windowmove 5
