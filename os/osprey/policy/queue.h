/* Single-producer/single-consumer queue used by Osprey syscall adapters. */
#ifndef OSPREY_QUEUE_H
#define OSPREY_QUEUE_H

#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#include <u.h>
#endif

typedef struct Message Message;
typedef struct Queue Queue;

enum {
	MessageWords = 8,
};

struct Message {
	uvlong	op;
	uvlong	sequence;
	uvlong	container;
	uvlong	arg[MessageWords-3];
};

struct Queue {
	Message	*message;
	uvlong	size;
	volatile uvlong	put;
	volatile uvlong	get;
};

int	queueinit(Queue*, Message*, uvlong);
int	queueput(Queue*, Message*);
int	queueget(Queue*, Message*);
uvlong	queuecount(Queue*);

#endif
