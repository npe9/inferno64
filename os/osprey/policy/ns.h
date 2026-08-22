#ifndef OSPREY_NS_H
#define OSPREY_NS_H

#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#include <u.h>
#endif

typedef struct Name Name;
typedef struct Ns Ns;

enum {
	Nnamelen = 32,
};

/*
 * The names are held rather than pointed at.  A caller's string is
 * usually a parsed command line that goes away as soon as the call
 * returns, and a table that can be copied whole is also what the
 * checkpoint layer needs.
 */
struct Name {
	char	local[Nnamelen];
	char	global[Nnamelen];
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
