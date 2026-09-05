#include	"lib9.h"

Rune*_runebsearch(Rune c, Rune *t, int n, int ne);

/*
 * The search the tables in runetypebody are built for: pairs (or
 * triples) of runes, sorted, and c is inside the range beginning at
 * the entry this returns.  runetypebody says at the top that it is
 * the standard table with rbsearch renamed, and nothing in this
 * library ever defined the renamed one -- isspacerune and its
 * relatives have been undefined symbols here for as long as the file
 * has existed, which nothing noticed until a host tool wanted them.
 */
Rune*
_runebsearch(Rune c, Rune *t, int n, int ne)
{
	Rune *p;
	int m;

	while(n > 1) {
		m = n >> 1;
		p = t + m*ne;
		if(c >= p[0]) {
			t = p;
			n = n-m;
		} else
			n = m;
	}
	if(n && c >= t[0])
		return t;
	return 0;
}

#include "runetypebody-6.2.0.h"
