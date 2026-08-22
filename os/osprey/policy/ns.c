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

static void
copy(char *d, char *s)
{
	char *e;

	for(e = d + Nnamelen - 1; d < e && *s != 0; )
		*d++ = *s++;
	*d = 0;
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
	i = find(ns, local);
	if(i >= 0){
		copy(ns->name[i].global, global);
		return 0;
	}
	if(ns->n >= ns->cap)
		return -1;
	copy(ns->name[ns->n].local, local);
	copy(ns->name[ns->n].global, global);
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
