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
