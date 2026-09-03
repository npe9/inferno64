#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * No display on this board yet (see screen.h and the armv7 board-config's
 * own note) -- just enough to satisfy main.c's screeninit() call and
 * devkprof.c's optional screenstats() hook.
 */
void
screeninit(void)
{
}

void
screenstats(void)
{
}
