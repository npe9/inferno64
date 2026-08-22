#include "snap.h"

int
snapsave(Process *p, Snap *s)
{
	if(p == nil || s == nil)
		return -1;
	s->id = p->id;
	s->core = p->core;
	s->state = p->state;
	s->container = p->container;
	s->reqput = p->requests->put;
	s->reqget = p->requests->get;
	s->repput = p->replies->put;
	s->repget = p->replies->get;
	s->ns = p->ns.n;
	return 0;
}

int
snapload(Process *p, Snap *s)
{
	if(p == nil || s == nil || s->id != p->id ||
		s->reqget > s->reqput || s->repget > s->repput ||
		s->reqput - s->reqget > p->requests->size ||
		s->repput - s->repget > p->replies->size || s->ns > p->ns.cap)
		return -1;
	p->core = s->core;
	p->state = s->state;
	p->container = s->container;
	p->requests->put = s->reqput;
	p->requests->get = s->reqget;
	p->replies->put = s->repput;
	p->replies->get = s->repget;
	return 0;
}
