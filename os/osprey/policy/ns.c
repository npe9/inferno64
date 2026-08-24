#include "ns.h"

int
nsinit(Ns *ns, Name *name, ulong cap)
{
	if(ns == nil || name == nil || cap == 0)
		return -1;
	ns->name = name;
	ns->n = 0;
	ns->cap = cap;
	return 0;
}

static long
same(char *a, char *b)
{
	while(*a != 0 && *a == *b){
		a++;
		b++;
	}
	return *a == *b;
}

/*
 * A name that does not fit is refused rather than cut short.  This table
 * decides what a container's open opens, so half a name is not a smaller
 * answer, it is a different one.
 */
static int
copy(char *d, char *s)
{
	char *e;

	for(e = d + Nnamelen - 1; d < e && *s != 0; )
		*d++ = *s++;
	*d = 0;
	return *s == 0 ? 0 : -1;
}

static int
fits(char *s)
{
	long i;

	for(i = 0; i < Nnamelen && s[i] != 0; i++)
		;
	return i < Nnamelen;
}

static long
find(Ns *ns, char *local)
{
	ulong i;
	if(ns == nil || local == nil)
		return -1;
	for(i = 0; i < ns->n; i++)
		if(same(ns->name[i].local, local))
			return i;
	return -1;
}

int
nsbind(Ns *ns, char *local, char *global)
{
	long i;
	if(ns == nil || local == nil || global == nil)
		return -1;
	if(*local == 0 || *global == 0)
		return -1;
	if(!fits(local) || !fits(global))
		return -1;
	i = find(ns, local);
	if(i >= 0)
		return copy(ns->name[i].global, global);
	if(ns->n >= ns->cap)
		return -1;
	if(copy(ns->name[ns->n].local, local) < 0
	|| copy(ns->name[ns->n].global, global) < 0)
		return -1;
	ns->n++;
	return 0;
}

int
nsunbind(Ns *ns, char *local)
{
	long i;
	if(ns == nil || local == nil)
		return -1;
	i = find(ns, local);
	if(i < 0)
		return -1;
	if((ulong)i != ns->n-1)
		ns->name[i] = ns->name[ns->n-1];
	ns->n--;
	return 0;
}

char*
nslookup(Ns *ns, char *local)
{
	long i;
	i = find(ns, local);
	return i < 0 ? nil : ns->name[i].global;
}
