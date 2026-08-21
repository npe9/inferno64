#include "net.h"

int
pktqinit(Pktq *q, Pkt **pkt, ulong size)
{
	if(q == nil || pkt == nil || size == 0)
		return -1;
	q->pkt = pkt;
	q->size = size;
	q->put = 0;
	q->get = 0;
	return 0;
}

int
pktqput(Pktq *q, Pkt *p)
{
	if(q == nil || p == nil || q->pkt == nil || q->size == 0 ||
		q->put - q->get >= q->size || p->container == nil ||
		netcharge(p->container, p->len, 1) < 0)
		return -1;
	q->pkt[q->put % q->size] = p;
	q->put++;
	return 0;
}

int
pktqget(Pktq *q, Pkt *p)
{
	Pkt *in;
	if(q == nil || p == nil || q->pkt == nil || q->size == 0 ||
		q->get == q->put)
		return -1;
	in = q->pkt[q->get % q->size];
	*p = *in;
	q->get++;
	return 0;
}

ulong
pktqcount(Pktq *q)
{
	return q == nil ? 0 : q->put - q->get;
}
