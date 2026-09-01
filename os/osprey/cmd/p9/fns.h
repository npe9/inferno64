#include "portfns.h"
extern Dev* devtab[];
extern char *eve;
#define DEVDOTDOT -1

/* run the kernel's error unwinding on user-space setjmp/longjmp */
extern int	setjmp(jmp_buf);
extern _Noreturn void longjmp(jmp_buf, int);
#undef waserror
#define waserror()	(up->nerrlab++, setjmp(up->errlab[up->nerrlab-1]))
#undef poperror
#define poperror()	(up->nerrlab--)
extern uint qiomaxatomic;
