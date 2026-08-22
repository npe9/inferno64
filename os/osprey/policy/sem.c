#include "sem.h"

void
seminit(Sem *s, uvlong count)
{
	if(s == nil)
		return;
	s->count = count;
	s->given = 0;
	s->taken = 0;
}

void
semgive(Sem *s)
{
	if(s == nil)
		return;
	s->count++;
	s->given++;
}

int
semtake(Sem *s)
{
	if(s == nil || s->count == 0)
		return -1;
	s->count--;
	s->taken++;
	return 0;
}

uvlong
semcount(Sem *s)
{
	return s == nil ? 0 : s->count;
}
