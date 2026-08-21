#ifndef OSPREY_NET_H
#define OSPREY_NET_H

#include "edf.h"

typedef struct Block Block;

typedef struct Pkt Pkt;
typedef struct Pktq Pktq;

struct Pkt {
	Block	*block;
	ulong	len;
	Container	*container;
};

struct Pktq {
	Pkt	**pkt;
	ulong	size;
	ulong	put;
	ulong	get;
};

int	pktqinit(Pktq*, Pkt**, ulong);
int	pktqput(Pktq*, Pkt*);
int	pktqget(Pktq*, Pkt*);
ulong	pktqcount(Pktq*);

#endif
