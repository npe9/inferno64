/*
 * runetest -- check the Unicode classification tables against answers
 * that are known without looking at the tables.
 *
 * These functions live in runetypebody-6.2.0.h and every one of them
 * goes through _runebsearch, which for most of this library's life
 * was declared in runetype.c and defined nowhere: nothing in the tree
 * called isspacerune or its relatives until a host tool did.  The
 * search is written out again in runetype.c now, and this says
 * whether it is right -- with both shapes of table, the pairs the
 * predicates use and the triples the case conversions use.
 *
 * Build and run with
 *
 *	mk runetest
 *
 * in this directory.  A silent success prints one line.
 */

#include <lib9.h>

extern int isdigitrune(Rune);

int
main(void)
{
	int bad = 0;

#define CHECK(e)	if(!(e)){ print("FAIL: %s\n", #e); bad = 1; }
	CHECK(isalpharune('a'))
	CHECK(isalpharune('Z'))
	CHECK(!isalpharune('0'))
	CHECK(!isalpharune(' '))
	CHECK(isspacerune(' '))
	CHECK(isspacerune('\t'))
	CHECK(!isspacerune('x'))
	CHECK(isdigitrune('7'))
	CHECK(!isdigitrune('x'))
	CHECK(isupperrune('A'))
	CHECK(!isupperrune('a'))
	CHECK(islowerrune('a'))
	CHECK(tolowerrune('A') == 'a')
	CHECK(toupperrune('a') == 'A')
	CHECK(tolowerrune('a') == 'a')
	/* non-ASCII: Greek capital alpha, Cyrillic capital A, e-acute */
	CHECK(isalpharune(0x391))
	CHECK(isupperrune(0x391))
	CHECK(tolowerrune(0x391) == 0x3b1)
	CHECK(toupperrune(0x3b1) == 0x391)
	CHECK(isalpharune(0x410))
	CHECK(tolowerrune(0x410) == 0x430)
	CHECK(isalpharune(0xc9))
	CHECK(tolowerrune(0xc9) == 0xe9)
	CHECK(toupperrune(0xe9) == 0xc9)
	CHECK(!isalpharune(0x2003))		/* em space */
	CHECK(isspacerune(0x2003))
	CHECK(isdigitrune(0x660))		/* arabic-indic zero */
	if(!bad)
		print("rune tables OK\n");
	return bad;
}
