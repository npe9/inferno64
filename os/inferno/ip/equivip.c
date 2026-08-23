/*
 * From os/9front/lib/equivip.c.  A kernel here builds it as kernel source
 * rather than linking the hosted libip, which os/inferno/port/
 * portmkfile would otherwise fetch from $ROOT/libip: its
 * readipifc.c opens and reads /net/ipifc.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"ip.h"

int
equivip4(uchar *a, uchar *b)
{
	int i;

	for(i = 0; i < 4; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

int
equivip6(uchar *a, uchar *b)
{
	int i;

	for(i = 0; i < IPaddrlen; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}
