#include "process.h"

int
processinit(Process *p, uvlong id, uvlong budget, uvlong period,
	uvlong deadline, Queue *requestq, Queue *replyq,
	Message *requests, Message *replies,
	uvlong queuesize, Name *names, ulong nnames)
{
	if(p == nil || requestq == nil || replyq == nil ||
		requests == nil || replies == nil || queuesize == 0 ||
		names == nil || nnames == 0)
		return -1;
	p->id = id;
	p->core = 0;
	p->state = ProcessNew;
	p->requests = requestq;
	p->replies = replyq;
	p->requeststorage = requests;
	p->repliestorage = replies;
	containerinit(&p->container, budget, period, deadline);
	if(nsinit(&p->ns, names, nnames) < 0)
		return -1;
	taskinit(&p->task, &p->container);
	if(queueinit(p->requests, requests, queuesize) < 0 ||
		queueinit(p->replies, replies, queuesize) < 0)
		return -1;
	return 0;
}

int
processsubmit(Process *p, Request *request)
{
	if(p == nil || request == nil || p->state == ProcessExited)
		return -1;
	request->container = p->id;
	request->message.sequence = request->sequence;
	request->message.container = request->container;
	request->message.arg[1] = request->flags;
	return queueput(p->requests, &request->message);
}

int
processreply(Process *p, Reply *reply)
{
	if(p == nil || reply == nil || p->state == ProcessExited)
		return -1;
	reply->message.sequence = reply->sequence;
	reply->message.arg[0] = reply->status;
	reply->message.arg[1] = reply->flags;
	return queueput(p->replies, &reply->message);
}

int
processnext(Process *p, Request *request)
{
	if(p == nil || request == nil)
		return -1;
	if(queueget(p->requests, &request->message) < 0)
		return -1;
	request->sequence = request->message.sequence;
	request->container = request->message.container;
	request->flags = request->message.arg[1];
	return 0;
}

int
processnextreply(Process *p, Reply *reply)
{
	if(p == nil || reply == nil)
		return -1;
	if(queueget(p->replies, &reply->message) < 0)
		return -1;
	reply->sequence = reply->message.sequence;
	reply->status = reply->message.arg[0];
	reply->flags = reply->message.arg[1];
	return 0;
}
