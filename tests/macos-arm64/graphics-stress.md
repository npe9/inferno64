# Graphics stress test

Build and install:

    cd appl/wm
    mk gfxstress.dis install

Run the complete one-second-per-phase check with the JIT:

    MacOSX/arm64/bin/emu -c1 /dis/wm/gfxstress.dis all 1

Run one phase for a longer profile:

    MacOSX/arm64/bin/emu -c1 /dis/wm/gfxstress.dis alpha 10

The phases are `fill`, `copy`, `overlap`, `alpha`, `mask`, `line`,
`ellipse`, `poly`, `text`, `upload`, `damage`, and `draw3d`. Each phase
prints its operation count, elapsed milliseconds, and operations per second.

`draw3dthick` specifically stresses synchronized queue handoff and bounded
backpressure with thick GPU lines; it is also included in `all`.
