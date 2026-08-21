#include <u.h>
#include <libc.h>

int
fork(void)
{
	return rfork(RFPROC|RFFDG|RFREND);
}

long
read(int fd, void *buf, long n)
{
	return pread(fd, buf, n, -1LL);
}

int
execl(char *file, ...)
{
	return exec(file, &file+1);
}
