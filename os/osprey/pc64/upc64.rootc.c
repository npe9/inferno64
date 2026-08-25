
#include "u.h"
#include <lib.h>
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include <error.h>

extern uchar bootcode[];
extern ulong bootlen;

void bootlinks(void){

	addbootfile("boot", bootcode, bootlen);

}

