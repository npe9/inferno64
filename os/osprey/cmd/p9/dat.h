#include "nsdat.h"
enum { NERR = 32 };
struct Proc {
	Pgrp *pgrp; Egrp *egrp; Fgrp *fgrp; Chan *dot; Chan *slash; Fgrp *closingfgrp;
	char *user; int procctl; char genbuf[128];
	char *errstr; char *syserrstr;
	int nerrlab; jmp_buf errlab[NERR];
	int nnote; int pid; char text[32]; Rendez sleep; int priority;
};
typedef struct Conf Conf;
struct Conf { ulong pipeqsize; };
extern Conf conf;
extern Proc *up;
