#include "lib9.h"

char*
strchr(char *s, int c)
{
	char *p;

	p = s;
	for(;;){
		if(*p == c)
			return p;
		if(*p++ == 0)
			return 0;
	}
}
