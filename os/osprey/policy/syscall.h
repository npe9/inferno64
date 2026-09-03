#ifndef OSPREY_SYSCALL_H
#define OSPREY_SYSCALL_H

#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#include <u.h>
#endif
#include "queue.h"

enum {
	ReqRead,
	ReqWrite,
	ReqOpen,
	ReqClose,
	ReqWait,
	ReqSend,
	ReqRecv,
	ReqStat,
	ReqBind,
	ReqAlloc,
	ReqYield,
	ReqPoll,
	/*
	 * Not a request a container makes: the kernel puts this on a
	 * server's ring when a container that server answers for has gone,
	 * so that the server can let go of what it was holding for it.
	 * Appended rather than inserted, so that a program built against
	 * an older copy of this list still numbers everything else the
	 * same.  Nothing answers it; there is nobody left to answer to.
	 */
	ReqGone,
	/*
	 * Start a program in a container of its own.  arg[2] is the offset,
	 * in the caller's data area, of the program's name in the caller's
	 * server's name space.  Answered by the kernel: it makes the
	 * container, delegates it to the caller's server, and that server
	 * lays the program out and pages it in as a buddy does; the reply's
	 * arg[2] is the new container's identity.  wait, above, is answered
	 * when a container this one started exits, with its status.
	 */
	ReqExec,
	/*
	 * A task's own reservation and its clock.  reserve: arg[2] and
	 * arg[3] are the budget and the period the task needs, in
	 * microseconds; the deadline is the period.  This is how a service
	 * that knows what it needs - a storage task that must reclaim its
	 * log at some rate - sets it, rather than having it compiled in or
	 * set by whoever created the container.  tick: arg[2] is a
	 * semaphore of the caller's which the clock interrupt gives on
	 * every tick of its core, or -1 to stop; a periodic task waits on
	 * it with select, the interrupt-to-task path.
	 */
	ReqReserve = 16,	/* 14 and 15 are the personalities' own on the ring: 9P and a forwarded system call */
	ReqTick,
};

enum {
	ReplyPending,
	ReplyDone,
	ReplyError,
	ReplyBlocked,
	ReplyRetry,
};

enum {
	ReqAsync = 1<<0,
	ReqMore = 1<<1,
	ReqReply = 1<<2,
};

typedef struct Request Request;
typedef struct Reply Reply;

struct Request {
	Message	message;
	uvlong	sequence;
	uvlong	container;
	ulong	flags;
};

struct Reply {
	Message	message;
	uvlong	sequence;
	long	status;
	ulong	flags;
};

#endif
