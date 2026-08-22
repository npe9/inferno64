/*
 * Counting semaphores.  A semaphore is one of the two things a select
 * arm can wait on, and the way an interrupt hands work to the task that
 * serves a device: the interrupt gives, the task takes.
 *
 * The count is visible to whoever maps the semaphore, so a task can see
 * that a take would succeed without asking the kernel.  The operations
 * themselves are not atomic; the adapter serialises them, as it does the
 * rest of this layer.
 */
#ifndef OSPREY_SEM_H
#define OSPREY_SEM_H

#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#include <u.h>
#endif

typedef struct Sem Sem;

struct Sem {
	volatile uvlong	count;
	volatile uvlong	given;	/* total ever given, for accounting */
	volatile uvlong	taken;
};

void	seminit(Sem*, uvlong);
void	semgive(Sem*);
int	semtake(Sem*);		/* 0 if taken, -1 if it would block */
uvlong	semcount(Sem*);

#endif
