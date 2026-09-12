/*
 * The kernel's external registers, all of them, in one place.
 *
 * kencc allocates external registers per file, by declaration order.
 * A file that declares only curP gets the first register; one that
 * declares m, up and curP gets the third.  So a register cannot be
 * shared between libinterp and the kernel unless both declare the same
 * set in the same order, which is what this header is for -- measured:
 * without it libinterp's curP was the kernel's m, and booting printed
 * "cpu3318001: registers for kernel", m->machno read through the
 * context pointer.
 *
 * The types are opaque on purpose.  libinterp is built with
 * $ROOT/include alone, because the same sources link into emu, so it
 * cannot see Mach or Proc -- and it does not need to, since it only
 * dereferences curP.  A kernel file gets the real structures from its
 * own dat.h after including this.
 *
 * Why a register at all: Go reaches the current goroutine through one
 * (R14 on amd64, R28 on arm64) so getg() is a register read.  This is
 * the same, and it is the only route libinterp can name -- a
 * per-process field would need Proc.
 *
 * Guarded because emu has no external registers; there curP stays an
 * ordinary global and the per-thread route is __thread, a separate
 * change.  Opted into per architecture: amd64 defines DISCTXREG, and an
 * architecture that does not simply keeps the global, which is the
 * behaviour every board had before this existed.
 */
#ifndef _DISREG_H_
#define _DISREG_H_
typedef struct Mach Mach;
typedef struct Proc Proc;
extern register Mach*	m;		/* R15 on amd64 */
extern register Proc*	up;		/* R14 */
#ifdef DISCTXREG
typedef struct Pctx Pctx;
extern register Pctx*	curP;		/* R13; the Dis context, interp.h */
/*
 * Sets curP to the default context.  A function rather than an
 * "extern Pctx* defpctx" a kernel file could read, because kencc
 * checks type signatures across objects (-T) and the Pctx declared
 * opaque here does not match libinterp's real one.  It works because
 * curP is a register no compiled code clobbers, so the assignment
 * libinterp makes is still there when it returns.
 */
void	disctxinit(void);
#endif
#endif
