/*
 * The host's unistd.h, and then Plan 9's dup.
 *
 * A Plan 9 program says dup(old, new): two arguments, the second the
 * file descriptor to make a copy on, or -1 for the lowest free one.
 * Here that call is dup2, and the host's own dup takes one argument,
 * so a host tool built from Plan 9 source -- cpp, whose nlist.c
 * redirects its output that way -- will not compile against the
 * declaration this file's own contents make.
 *
 * lib9.h includes <unistd.h>, and the host directory is searched
 * before the system's, so this file is what it finds.  It pulls in
 * the real one with #include_next and then puts the Plan 9 spelling
 * over the top, where it cannot collide with a declaration that has
 * already been read.  A one-argument dup would break, and nothing
 * built here has one.
 */
#ifndef __9FRONT_HOST_UNISTD_H
#define __9FRONT_HOST_UNISTD_H

#include_next <unistd.h>

#undef dup
#define dup(old, new) dup2(old, new)

#endif
