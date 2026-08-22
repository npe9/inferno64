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

/*
 * Supplied by the architecture adapter.  A ring may be shared between a
 * core and a user process on another core, so the message must be visible
 * before the index that publishes it, and the index must be read before
 * the message it refers to.  On a machine that needs no instruction for
 * that, the adapter may define this as an empty function.
 */
void	queuebarrier(void);

int	queueinit(Queue*, Message*, uvlong);
int	queueput(Queue*, Message*);
int	queueget(Queue*, Message*);
uvlong	queuecount(Queue*);
int	queuefull(Queue*);
int	queueempty(Queue*);

#endif
