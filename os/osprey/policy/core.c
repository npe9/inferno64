#include "core.h"

void
coreinit(Core *c, ulong id)
{
	c->id = id;
	c->runq = nil;
	c->current = nil;
	c->cycles = 0;
	c->contextswitches = 0;
}

void
coreenqueue(Core *c, Task *t, uvlong now)
{
	if(t == nil)
		return;
	if(t->runnable)
		edfremove(&c->runq, t);
	taskrelease(t, now);
	edfinsert(&c->runq, t);
}

void
coredequeue(Core *c, Task *t)
{
	if(t == nil)
		return;
	edfremove(&c->runq, t);
	if(c->current == t)
		c->current = nil;
}

Task*
corenext(Core *c)
{
	Task *next;

	next = edfnext(c->runq);
	if(next != c->current)
		c->contextswitches++;
	c->current = next;
	return next;
}

int
corecharge(Core *c, uvlong amount, uvlong now)
{
	if(c == nil)
		return -1;
	c->cycles += amount;
	if(c->current != nil && c->current->container != nil)
		return containercharge(c->current->container, amount, now);
	return 0;
}
