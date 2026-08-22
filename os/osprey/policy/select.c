#include "select.h"

static int
armready(Arm *a)
{
	switch(a->op){
	case MSget:
		return a->q != nil && !queueempty(a->q);
	case MSput:
		return a->q != nil && !queuefull(a->q);
	case MSdown:
		return a->s != nil && semcount(a->s) > 0;
	}
	return 0;
}

int
selectready(Arm *a, int n)
{
	int i;

	if(a == nil)
		return -1;
	for(i = 0; i < n; i++){
		if(a[i].op == MSlast)
			break;
		if(armready(&a[i]))
			return i;
	}
	return -1;
}

int
selectscan(Arm *a, int n)
{
	int i;

	if((i = selectready(a, n)) < 0)
		return -1;
	switch(a[i].op){
	case MSget:
		if(queueget(a[i].q, a[i].m) < 0)
			return -1;
		break;
	case MSput:
		if(queueput(a[i].q, a[i].m) < 0)
			return -1;
		break;
	case MSdown:
		if(semtake(a[i].s) < 0)
			return -1;
		break;
	}
	return i;
}
