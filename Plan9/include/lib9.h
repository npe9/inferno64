#include <u.h>
typedef usize size_t;

#define	Rendez	xRendez
#define	setmalloctag	p9setmalloctag
#define	setrealloctag	p9setrealloctag
#define	getmalloctag	p9getmalloctag
#define	getrealloctag	p9getrealloctag
#include <libc.h>
#undef Rendez
#undef setmalloctag
#undef setrealloctag
#undef getmalloctag
#undef getrealloctag

/*
 *	Extensions for Inferno to basic libc.h
 */

#define	setbinmode()
#define	USE_FPdbleword

#define	DBG	if(debug)print

extern	void	setmalloctag(void*, uintptr);
extern	void	setrealloctag(void*, uintptr);
extern	uintptr	getmalloctag(void*);
extern	uintptr	getrealloctag(void*);
