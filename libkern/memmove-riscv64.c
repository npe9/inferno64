#include "lib9.h"

void*
memmove(void *a1, void *a2, usize n)
{
	char *s1, *s2;

	if(n == 0)
		return a1;
	/*
	 * growparse() memmoves from a nil elems pointer on first growth.
	 * Page 0 is not mapped on QEMU virt; treat nil source as zeros.
	 */
	if(a2 == nil){
		memset(a1, 0, n);
		return a1;
	}
	s1 = a1;
	s2 = a2;
	if(s2 < s1 && s2+n > s1)
		goto back;
	while(n > 0){
		*s1++ = *s2++;
		n--;
	}
	return a1;

back:
	s1 += n;
	s2 += n;
	while(n > 0){
		*--s1 = *--s2;
		n--;
	}
	return a1;
}

void*
memcpy(void *a1, void *a2, usize n)
{
	return memmove(a1, a2, n);
}
