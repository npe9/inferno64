/*
 * The Plan 9 personality's image, for a kernel that does not run one.
 *
 * p9progimg.c is the other half of this: the image itself, two megabytes
 * of it, linked into the four configurations that load a personality.
 * This stands in its place in the others, so that ospreyloadp9 links
 * everywhere and says what is wrong by name if it is ever reached in a
 * kernel that has no personality to load.
 */
#include	"u.h"
#include	"../port/lib.h"

uchar	p9prog[1];
int	p9proghere = 0;
