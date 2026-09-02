#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"p9file.h"

/*
 * The buddy operating system's syscall emulation, in the paper's sense:
 * an unmodified Plan 9 binary runs in a container of its own and traps in
 * the Plan 9 system-call ABI; the microkernel forwards each trap to this
 * peer, which emulates the syscall against its own name space and file-
 * descriptor table - open, read, write, close - and hands the answer
 * back.  The legacy binary never knows a peer served it.  This is per-
 * process interposition (the buddy holds the descriptor table that stands
 * for the legacy process's), not a shared server; and for now it
 * interposes system calls only, not page faults - the legacy image is
 * eager-mapped so it does not fault.
 *
 * The kernel has copied any pointer argument (a name, a data buffer) into
 * the legacy container's data area, which this peer reaches as cdata; the
 * handler reads names from there and writes read data back there.
 */

enum {
	/* Plan 9 amd64 system-call numbers (os/osprey/port/sys.h) */
	CLOSE	= 4,
	OPEN	= 14,
	_READ	= 15,
	OSEEK	= 16,
	_WRITE	= 20,
	SEEK	= 39,
	PREAD	= 50,
	PWRITE	= 51,

	Argoff	= 64,		/* where the kernel left the arg block, in cdata */
	Nameoff	= 256,		/* where the kernel left a name, in cdata */
	Dataoff	= 1024,		/* where read/write data goes, in cdata */
};

/*
 * Serve one forwarded Plan 9 system call.  scallnr is the trap number;
 * a0..a2 are its scalar arguments (a descriptor, a count, an offset, a
 * mode); cdata is the legacy container's data area.  Returns the value
 * the system call yields, which the kernel puts back in the legacy
 * process's result register.
 */
long
p9buddy_syscall(uvlong scallnr, uvlong a0, uvlong a1, uvlong a2, uchar *cdata)
{
	long r;

	switch(scallnr){
	case OPEN:
		/* open(name, mode): name at cdata[Nameoff], mode a1 */
		r = p9open((char*)(cdata + Nameoff), (int)a1);
		break;

	case CLOSE:
		p9close((int)a0);
		r = 0;
		break;

	case _READ:
		/* read(fd, buf, n): fd a0, n a1; data to cdata[Dataoff] */
		r = p9read((int)a0, cdata + Dataoff, (long)a1);
		break;

	case PREAD:
		/* pread(fd, buf, n, off): fd a0, n a1, off a2 */
		if((vlong)a2 >= 0)
			p9seek((int)a0, (vlong)a2, 0);
		r = p9read((int)a0, cdata + Dataoff, (long)a1);
		break;

	case _WRITE:
		/* write(fd, buf, n): data already at cdata[Dataoff] */
		r = p9write((int)a0, cdata + Dataoff, (long)a1);
		break;

	case PWRITE:
		if((vlong)a2 >= 0)
			p9seek((int)a0, (vlong)a2, 0);
		r = p9write((int)a0, cdata + Dataoff, (long)a1);
		break;

	case SEEK:
	case OSEEK:
		r = (long)p9seek((int)a0, (vlong)a1, (int)a2);
		break;

	default:
		r = -1;		/* a trap this buddy does not emulate */
		break;
	}
	return r;
}

/*
 * Plain-typed entry the user-header ring loop calls.  The kernel left the
 * forwarded call's number and scalar arguments as a block of uvlongs at
 * cdata[Argoff]: number, then the three scalars.
 */
long
p9buddy_serve(uchar *cdata)
{
	uvlong *ab;

	ab = (uvlong*)(cdata + Argoff);
	return p9buddy_syscall(ab[0], ab[1], ab[2], ab[3], cdata);
}
