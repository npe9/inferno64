#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

void
mmuinit(void)
{
	/* MMU stays off -- identity/physical addressing throughout, the
	 * same choice os/inferno/virt makes for riscv64's bare M-mode.
	 * There is one privilege level and no user/kernel address-space
	 * split on this board; Dis is the isolation boundary. */
}
