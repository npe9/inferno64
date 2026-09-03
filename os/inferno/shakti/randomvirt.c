/*
 * Entropy for /dev/random.  Prefer virtio-rng via hwrandbuf (rngvirtiommio);
 * otherwise a tick-seeded LCG (smoke/dev only).
 *
 * os/port/random.c needs ChaCha/SHA2_512, which Inferno libsec does not ship.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

void (*hwrandbuf)(void*, u32) = nil;

static ulong seed = 1;
static Lock lk;

void
randominit(void)
{
	seed = m->ticks ^ 0x9e3779b9;
	if(seed == 0)
		seed = 1;
}

ulong
randomread(void *p, ulong n)
{
	uchar *a;
	ulong i;

	if(n == 0)
		return 0;

	if(hwrandbuf != nil){
		(*hwrandbuf)(p, n);
		return n;
	}

	a = p;
	ilock(&lk);
	for(i = 0; i < n; i++){
		seed = seed * 1103515245 + 12345;
		a[i] = seed >> 16;
	}
	iunlock(&lk);
	return n;
}

void
genrandom(uchar *p, int n)
{
	randomread(p, n);
}

long
lrand(void)
{
	ulong x;

	randomread(&x, sizeof(x));
	return x & 0x7fffffff;
}
