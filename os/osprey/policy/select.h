/*
 * Waiting on several things at once.
 *
 * A caller offers an array of arms, each naming a message ring to take
 * from or add to, or a semaphore to take.  The scan performs the first
 * arm that is ready and answers which one that was.  An arm is turned
 * off in place, by setting its operation to MSnoop, rather than the
 * array being built again; a driver that has no room in its output fifo
 * does exactly that with the arm that would read its output queue.
 *
 * Blocking is not here.  This layer has nothing to sleep on: it says
 * whether anything is ready, and the kernel adapter waits when nothing
 * is.
 */
#ifndef OSPREY_SELECT_H
#define OSPREY_SELECT_H

#include "queue.h"
#include "sem.h"

enum {
	MSlast,		/* end of the array */
	MSnoop,		/* this arm is turned off */
	MSget,		/* take a message from a ring */
	MSput,		/* add a message to a ring */
	MSdown,		/* take a semaphore */
};

typedef struct Arm Arm;

struct Arm {
	int	op;
	Queue	*q;
	Sem	*s;
	Message	*m;	/* taken into, or added from */
};

int	selectready(Arm*, int);		/* index of a ready arm, or -1 */
int	selectscan(Arm*, int);		/* perform one, or -1 */

#endif
