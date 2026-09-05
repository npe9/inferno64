/*
 * The host's time.h, and then Plan 9's ctime.
 *
 * A Plan 9 program says ctime(sec): the seconds themselves, not a
 * pointer to them, and the string it gets back has the time zone in
 * it, so the year is at offset 24 rather than 20.  cpp uses both
 * facts -- it calls ctime(time(0)) for __DATE__ and __TIME__, and
 * macro.c reaches past the zone for the year with a comment saying so.
 * Passing a long where the host wants a pointer crashes inside
 * localtime, which is what cpp did here: it died on every source and
 * pcc, piping into the compiler, turned that into an empty object
 * file and no message.
 *
 * The host directory is searched first, so this is the time.h a Plan 9
 * source gets.  It pulls in the real one and then puts the Plan 9
 * spelling over the top, out of reach of the declaration already read.
 */
#ifndef __9FRONT_HOST_TIME_H
#define __9FRONT_HOST_TIME_H

#include_next <time.h>

extern char *_p9ctime(long);

#undef ctime
#define ctime(sec) _p9ctime(sec)

#endif
