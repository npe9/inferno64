#ifndef OSPREY_RUNTIME_H
#define OSPREY_RUNTIME_H

#include "process.h"

typedef struct Runtime Runtime;
typedef int (*Handler)(Process*, Request*, Reply*, void*);

struct Runtime {
	Core *core;
	ulong ncore;
	Process **process;
	ulong nprocess;
	uvlong now;
};

int runtimeinit(Runtime*, Core*, ulong, Process**, ulong);
int runtimeattach(Runtime*, Process*, ulong);
int runtimedetach(Runtime*, Process*);
int runtimeblock(Runtime*, Process*);
int runtimewake(Runtime*, Process*, uvlong);
int runtimeexit(Runtime*, Process*);
int runtimebalance(Runtime*, uvlong);
Task* runtimenext(Runtime*, ulong, uvlong);
int runtimeserve(Runtime*, Process*, Handler, void*);

#endif
