#ifndef OSPREY_SNAP_H
#define OSPREY_SNAP_H

#include "process.h"

typedef struct Snap Snap;

struct Snap {
	uvlong	id;
	ulong	core;
	int	state;
	Container	container;
	uvlong	reqput;
	uvlong	reqget;
	uvlong	repput;
	uvlong	repget;
	ulong	ns;
};

int	snapsave(Process*, Snap*);
int	snapload(Process*, Snap*);

#endif
