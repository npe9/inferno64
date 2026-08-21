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
