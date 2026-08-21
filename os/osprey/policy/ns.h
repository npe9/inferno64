#ifndef OSPREY_NS_H
#define OSPREY_NS_H

#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#include <u.h>
#endif

typedef struct Name Name;
typedef struct Ns Ns;

struct Name {
	char	*local;
	char	*global;
};

struct Ns {
	Name	*name;
	ulong	n;
	ulong	cap;
};

int	nsinit(Ns*, Name*, ulong);
int	nsbind(Ns*, char*, char*);
int	nsunbind(Ns*, char*);
char*	nslookup(Ns*, char*);

#endif
