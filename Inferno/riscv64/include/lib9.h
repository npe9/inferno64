#ifndef _INFERNO_RISCV64_LIB9_H_
#define _INFERNO_RISCV64_LIB9_H_

#include "u.h"
#include "kern.h"

/*
 *	Extensions for Inferno to basic libc.h
 */

#define __LITTLE_ENDIAN	/* math/dtoa.c only */
/*
 * fdlibm __HI/__LO via int* punning is unreliable with KenC;
 * FPdbleword.lo/hi (little-endian) matches IEEE754 layout.
 */
#define USE_FPdbleword

#endif
