#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

enum {
	DOMLEN	= 48,
};

char	*eve;
char	hostdomain[DOMLEN] = "inferno";

int
iseve(void)
{
	return strcmp(eve, up->env->user) == 0;
}

long
hostownerwrite(char *data, int n)
{
	char buf[128];

	if(!iseve())
		error(Eperm);
	if(n <= 0 || n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, data, n);
	if(buf[n-1] == '\n')
		n--;
	buf[n] = '\0';
	kstrdup(&eve, buf);
	return n;
}

long
hostdomainwrite(char *data, int n)
{
	char buf[DOMLEN];

	if(!iseve())
		error(Eperm);
	if(n <= 0 || n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, data, n);
	if(buf[n-1] == '\n')
		n--;
	buf[n] = '\0';
	memmove(hostdomain, buf, n+1);
	return n;
}

long
userwrite(char *data, int n)
{
	char buf[128];

	if(n <= 0 || n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, data, n);
	if(buf[n-1] == '\n')
		n--;
	buf[n] = '\0';
	kstrdup(&up->env->user, buf);
	return n;
}
