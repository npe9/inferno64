#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
extern void p9init(void);
extern void exits(char*);
void
main(void)
{
	p9init();
	print("p9: namespace library linked\n");
	exits(nil);
}
