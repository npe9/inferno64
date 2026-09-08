/*
 * devdrawp9.c - the draw device, as a device of this personality.
 *
 * os/osprey/cmd/draw/devdraw.c is the kernel's draw device.  The
 * user-level draw server compiles it against kshim.h, which stands in
 * for the kernel types it uses - Chan, Dev, the error stack, the
 * allocator - because that server is an ordinary program.  This
 * personality does not need a stand-in: it is the kernel's own upper
 * half, compiled as a program, and those types are the ones its name
 * space is already built from.  So the same file is included here with
 * the personality's headers under it and no shim at all, and the device
 * it defines goes into devtab beside the root, the mount device and the
 * rest.
 *
 * That is what track three of the plan means by a library operating
 * system: the program that draws and the code that serves /dev/draw are
 * one address space, and a draw is a call.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * The kernel's readstr is the shim's kreadstr under another name; the
 * shim renamed it because libc has a readstr of its own.  Here the
 * kernel's is the one in scope.
 */
#define kreadstr readstr

#define Drawinpersonality 1
#include	"../draw/devdraw.c"
