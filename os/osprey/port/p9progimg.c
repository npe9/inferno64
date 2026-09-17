/*
 * The Plan 9 personality's image, as a kernel object of its own.
 *
 * It is two megabytes - the personality, the programs it loads, the
 * fonts and the boot files, all as byte arrays in its data - and four of
 * this flavour's seven configurations run it.  The other three were
 * carrying it for nothing, and it was not free: the EFI loader claims a
 * kernel's load region from the conventional memory below 8MB, and 9pc64
 * grew past what is there.  The loader said so and halted rather than
 * reading into memory that was not its own ("the region the kernel links
 * at is not free"), which is the right behaviour and is how this was
 * found.
 *
 * So the image is a separate object, linked into the kernels that load
 * it and not into the others; p9progstub.c is what the others link
 * instead.  Selecting an object is how this mkfile already chooses what
 * a configuration contains (PORTOBJ), and unlike a compile-time flag it
 * cannot go stale when CONF changes: the object is either on the link
 * line or it is not, while an object compiled with a different flag for
 * a different CONF would not be rebuilt when the CONF changed under it.
 */
#include	"u.h"
#include	"../port/lib.h"

#include	"p9prog.i"

int p9proghere = 1;
