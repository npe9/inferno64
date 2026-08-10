#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

void (*memdrawcopy)(Memimage*, Rectangle, Memimage*, Rectangle);

int
hwdraw(Memdrawparam *p)
{
	USED(p);
	return 0;	/* could not satisfy request */
}
