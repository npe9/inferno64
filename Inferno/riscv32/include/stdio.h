/*
 * Minimal ANSI stdio for KenC -p (freetype ftstdlib.h).
 * Inferno uses sprint; map sprintf for FreeType.
 */
#ifndef _INFERNO_STDIO_H_
#define _INFERNO_STDIO_H_
#include <lib9.h>
#define sprintf	sprint
#ifndef NULL
#define NULL	nil
#endif
#ifndef SEEK_SET
#define SEEK_SET	0
#define SEEK_CUR	1
#define SEEK_END	2
#endif
#endif
