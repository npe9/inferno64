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
	/*
	 * The rings are named rather than embedded so that the adapter can
	 * place them in memory a user process also maps, while the
	 * scheduling state above stays private to the kernel.
	 */
	Queue	*requests;
	Queue	*replies;
	/*
	 * And what a driver task takes its work from.  The presentation's
	 * driver selects on three things: the messages sent to it, the
	 * semaphore its interrupt gives, and this.
	 */
	Queue	*output;
	Message	*requeststorage;
	Message	*repliestorage;
	Message	*outputstorage;
};

enum {
	ProcessNew,
	ProcessRunnable,
	ProcessBlocked,
	ProcessExited,
};

int	processinit(Process*, uvlong, uvlong, uvlong, uvlong,
	Queue*, Queue*, Queue*, Message*, Message*, Message*, uvlong,
	Name*, ulong);
int	processsubmit(Process*, Request*);
int	processreply(Process*, Reply*);
int	processnext(Process*, Request*);
int	processnextreply(Process*, Reply*);

#endif
