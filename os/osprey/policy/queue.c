#include "queue.h"

int
queueinit(Queue *q, Message *message, uvlong size)
{
	if(q == nil || message == nil || size == 0)
		return -1;
	q->message = (uchar*)message - (uchar*)q;
	q->size = size;
	q->put = 0;
	q->get = 0;
	return 0;
}

int
queueput(Queue *q, Message *m)
{
	uvlong put, get;

	if(q == nil || q->message == 0 || m == nil || q->size == 0)
		return -1;
	put = q->put;
	get = q->get;
	if(q->size == 0 || put - get >= q->size)
		return -1;
	QMESSAGE(q)[put % q->size] = *m;
	queuebarrier();		/* message visible before the index */
	q->put = put + 1;
	return 0;
}

int
queueget(Queue *q, Message *m)
{
	uvlong put, get;

	if(q == nil || q->message == 0 || m == nil || q->size == 0)
		return -1;
	get = q->get;
	put = q->put;
	if(get == put)
		return -1;
	queuebarrier();		/* index read before the message */
	*m = QMESSAGE(q)[get % q->size];
	q->get = get + 1;
	return 0;
}

uvlong
queuecount(Queue *q)
{
	if(q == nil)
		return 0;
	return q->put - q->get;
}

int
queuefull(Queue *q)
{
	if(q == nil || q->size == 0)
		return 1;
	return q->put - q->get >= q->size;
}

int
queueempty(Queue *q)
{
	if(q == nil)
		return 1;
	return q->put == q->get;
}
