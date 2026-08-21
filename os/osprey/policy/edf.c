#include "edf.h"

static uvlong sequence;

void
containerinit(Container *c, uvlong budget, uvlong period, uvlong deadline)
{
	c->budget = budget;
	c->period = period;
	c->deadline = deadline;
	c->used = 0;
	c->epoch = 0;
	c->memory = 0;
	c->memused = 0;
	c->netbytes = 0;
	c->netpackets = 0;
	c->netmax = 0;
	c->packetmax = 0;
}

void
containerrefill(Container *c, uvlong now)
{
	uvlong n;

	if(c == nil || c->period == 0)
		return;
	n = now / c->period;
	if(n != c->epoch){
		c->epoch = n;
		c->used = 0;
	}
}

int
containercharge(Container *c, uvlong amount, uvlong now)
{
	if(c == nil)
		return -1;
	containerrefill(c, now);
	if(amount > c->budget - (c->used < c->budget ? c->used : c->budget))
		return -1;
	c->used += amount;
	return 0;
}

int
memcharge(Container *c, ulong amount)
{
	if(c == nil || amount > c->memory -
		(c->memused < c->memory ? c->memused : c->memory))
		return -1;
	c->memused += amount;
	return 0;
}

void
memrelease(Container *c, ulong amount)
{
	if(c == nil)
		return;
	if(amount >= c->memused)
		c->memused = 0;
	else
		c->memused -= amount;
}

int
netcharge(Container *c, ulong bytes, ulong packets)
{
	if(c == nil || bytes > c->netmax -
		(c->netbytes < c->netmax ? c->netbytes : c->netmax) ||
		packets > c->packetmax -
		(c->netpackets < c->packetmax ? c->netpackets : c->packetmax))
		return -1;
	c->netbytes += bytes;
	c->netpackets += packets;
	return 0;
}

void
netrelease(Container *c, ulong bytes, ulong packets)
{
	if(c == nil)
		return;
	if(bytes >= c->netbytes)
		c->netbytes = 0;
	else
		c->netbytes -= bytes;
	if(packets >= c->netpackets)
		c->netpackets = 0;
	else
		c->netpackets -= packets;
}

void
taskinit(Task *t, Container *c)
{
	t->next = nil;
	t->container = c;
	t->release = 0;
	t->deadline = ~0ULL;
	t->sequence = 0;
	t->runnable = 0;
}

void
taskrelease(Task *t, uvlong now)
{
	if(t == nil || t->container == nil)
		return;
	containerrefill(t->container, now);
	t->release = now;
	t->deadline = now + t->container->deadline;
	t->sequence = ++sequence;
	t->runnable = 1;
}

static int
before(Task *a, Task *b)
{
	if(a->deadline != b->deadline)
		return a->deadline < b->deadline;
	return a->sequence < b->sequence;
}

void
edfinsert(Task **head, Task *t)
{
	Task **p;

	if(t == nil || !t->runnable)
		return;
	for(p = head; *p != nil && !before(t, *p); p = &(*p)->next)
		;
	t->next = *p;
	*p = t;
}

void
edfremove(Task **head, Task *t)
{
	Task **p;

	for(p = head; *p != nil; p = &(*p)->next)
		if(*p == t){
			*p = t->next;
			t->next = nil;
			t->runnable = 0;
			return;
		}
}

Task*
edfnext(Task *head)
{
	return head;
}

int
budgetok(Task *t, uvlong amount)
{
	if(t == nil || t->container == nil)
		return 0;
	return amount <= t->container->budget -
		(t->container->used < t->container->budget ? t->container->used : t->container->budget);
}
