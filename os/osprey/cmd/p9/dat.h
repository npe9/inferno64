#include "nsdat.h"
enum { NERR = 32 };
struct Proc {
	Pgrp *pgrp; Chan *dot; Chan *slash; Fgrp *closingfgrp;
	char *user; int procctl; char genbuf[128];
	char *errstr; char *syserrstr;
	int nerrlab; jmp_buf errlab[NERR];
};
extern Proc *up;
