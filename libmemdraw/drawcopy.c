#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

/*
 * These live apart from hwdraw so that a kernel with its own hwdraw does
 * not drag the default one in behind them: draw.c needs these two, and
 * pulling the member that holds them used to pull a second definition of
 * hwdraw with it.
 */
void (*memdrawcopybegin)(Memimage*, Rectangle, Memimage*, Rectangle);
void (*memdrawcopy)(Memimage*, Rectangle, Memimage*, Rectangle);
