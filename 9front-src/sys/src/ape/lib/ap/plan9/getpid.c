#include "lib.h"
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include "sys9.h"

typedef long long vlong;
typedef unsigned long ulong;
typedef unsigned long long uvlong;
#include	"/Users/npe/src/inferno64-branches/pr-bluetooth/9front-src/sys/include/tos.h"

pid_t
getpid(void)
{
	return _tos->pid;
}
