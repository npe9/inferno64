/*
 * Osprey scheduling policy.
 *
 * This layer deliberately contains no Proc, Mach, or device dependencies.
 * The kernel adapter owns the task storage and supplies the clock value.
 * That keeps EDF policy testable before it is connected to traps and cores.
 */
#ifndef OSPREY_EDF_H
#define OSPREY_EDF_H

#ifndef OSPREY_U_INCLUDED
#define OSPREY_U_INCLUDED
#include <u.h>
#endif

typedef struct Container Container;
typedef struct Task Task;

struct Container {
	uvlong	budget;
	uvlong	period;
	uvlong	deadline;
	uvlong	used;
	uvlong	epoch;
	ulong	memory;
	ulong	memused;
	ulong	netbytes;
	ulong	netpackets;
	ulong	netmax;
	ulong	packetmax;
};

struct Task {
	Task	*next;
	Container	*container;
	uvlong	release;
	uvlong	deadline;
	uvlong	sequence;
	int	runnable;
};

void	containerinit(Container*, uvlong, uvlong, uvlong);
void	containerrefill(Container*, uvlong);
int	containercharge(Container*, uvlong, uvlong);
int	memcharge(Container*, ulong);
void	memrelease(Container*, ulong);
int	netcharge(Container*, ulong, ulong);
void	netrelease(Container*, ulong, ulong);
void	taskinit(Task*, Container*);
void	taskrelease(Task*, uvlong);
void	edfinsert(Task**, Task*);
void	edfremove(Task**, Task*);
Task*	edfnext(Task*);
int	budgetok(Task*, uvlong);

#endif
