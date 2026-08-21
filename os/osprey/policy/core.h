#ifndef OSPREY_CORE_H
#define OSPREY_CORE_H

#include "edf.h"

typedef struct Core Core;

struct Core {
	ulong	id;
	Task	*runq;
	Task	*current;
	uvlong	cycles;
	uvlong	contextswitches;
};

void	coreinit(Core*, ulong);
void	coreenqueue(Core*, Task*, uvlong);
void	coredequeue(Core*, Task*);
Task*	corenext(Core*);
int	corecharge(Core*, uvlong, uvlong);

#endif
