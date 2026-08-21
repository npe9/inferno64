#ifndef OSPREY_PROCESS_H
#define OSPREY_PROCESS_H

#include "core.h"
#include "syscall.h"
#include "ns.h"

typedef struct Process Process;

struct Process {
	uvlong	id;
	ulong	core;
	int	state;
	Container	container;
	Ns	ns;
	Task	task;
	Queue	requests;
	Queue	replies;
	Message	*requeststorage;
	Message	*repliestorage;
};

enum {
	ProcessNew,
	ProcessRunnable,
	ProcessBlocked,
	ProcessExited,
};

int	processinit(Process*, uvlong, uvlong, uvlong, uvlong,
	Message*, Message*, uvlong, Name*, ulong);
int	processsubmit(Process*, Request*);
int	processreply(Process*, Reply*);
int	processnext(Process*, Request*);
int	processnextreply(Process*, Reply*);

#endif
