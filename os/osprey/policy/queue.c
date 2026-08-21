#include "queue.h"

int
queueinit(Queue *q, Message *message, uvlong size)
{
	if(q == nil || message == nil || size == 0)
		return -1;
	q->message = message;
	q->size = size;
	q->put = 0;
	q->get = 0;
	return 0;
}

int
queueput(Queue *q, Message *m)
{
	uvlong put, get;

	if(q == nil || q->message == nil || m == nil || q->size == 0)
		return -1;
	put = q->put;
	get = q->get;
	if(q->size == 0 || put - get >= q->size)
		return -1;
	q->message[put % q->size] = *m;
	/* The kernel adapter supplies the architecture write barrier. */
	q->put = put + 1;
	return 0;
}

int
queueget(Queue *q, Message *m)
{
	uvlong put, get;

	if(q == nil || q->message == nil || m == nil || q->size == 0)
		return -1;
	get = q->get;
	put = q->put;
	if(get == put)
		return -1;
	*m = q->message[get % q->size];
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
