#ifndef OSPREYDATA_H
#define OSPREYDATA_H
/*
 * One layout for a container's data area.
 *
 * A container's data area holds, by role, the select arms, the message
 * a select took off the output queue, the 9P a client and its server
 * exchange, the buddy's argument and data blocks for a legacy process,
 * the migration header and staging, the tickets a pi-p session proves
 * itself with, and the block and network device descriptors.  These
 * were constants in five files; here they are once, so every user
 * reads the same offsets and the CTASSERTs below fail the build if two
 * regions that share a data area ever overlap.
 *
 * Roles that never share a container's data area may share an offset
 * (a legacy container's buddy blocks and a server's 9P, say); the
 * asserts check only the regions that do coexist.  Sizes are the extent
 * each region needs, for the overlap checks.
 */
enum {
	/* every container: the select arms at the start, and where a taken message lands */
	Odarm		= 0,
	Odarmlen	= 128,
	Odtaken		= 128,		/* a message select took off the output queue */
	Odtakenlen	= 128,

	/* a client and its server: the 9P transaction buffers */
	Odt9		= 256,		/* the T-message a client sends */
	Odt9len		= 768,
	Odr9		= 1024,		/* the R-message its server returns */
	Odr9len		= 2048,

	/* a legacy container: the buddy's blocks (this container has no 9P of its own) */
	Odbuddyarg	= 64,		/* the kernel's argument block for a forwarded call */
	Odbuddyarglen	= 192,
	Odbuddyname	= 256,		/* a path the call names */
	Odbuddynamelen	= 768,
	Odbuddydata	= 1024,		/* the call's data, a page */
	Odbuddydatalen	= 4096,

	/* a server carrying or taking a process over the wire */
	Odmig		= 1024,		/* the migration header (segments, register frame) */
	Odmiglen	= 2048,
	Odmighdrwords	= 4,		/* words of the migration header before its segment array: the segment count, the flags, the heap segment's index and the break in it */
	Odmigrx		= 5120,		/* the receiver's staging, clear of the sender's and the block ring */
	Odmigrxlen	= 2048,

	/* pi-p tickets, in a server's or a client's data area */
	Odticket	= 3072,		/* a ticket the wire server gives its kernel to check */
	Odticketlen	= 256,
	Odticketcliff	= 3328,		/* a ticket the client signs for itself, clear of the server's window */
	Odticketclifflen = 256,
	Odclientticket	= 3584,		/* a client's own ticket window (its ring data area, clear of 9P/arms/exec) */
	Odclientticketlen = 128,

	Odexecname	= 3072,		/* where an exec's name goes, clear of 9P (a client's data area) */
	Odexecnamelen	= 512,

	/* the block and network device descriptors, and where a block driver keeps its queue */
	Ospreyblkoff	= 3584,
	Ospreynetoff	= 3712,
	Ospreyblkring	= 4096,

	/* the console, keyboard and mouse containers, each its own data area */
	Odcons		= 1024,		/* the console task's staging ring */
	Odkbd		= 1024,		/* the keyboard container's scancode ring */
	Odkbdlen	= 1024,
	Odmouse		= 2048,		/* the mouse container's aux-byte ring */
	Odmouselen	= 1024,
};

/*
 * The build fails if two regions that share one data area overlap: each
 * term below is 1 when its region ends at or before the next begins,
 * and 0 when it does not, so a false one divides by zero and the
 * constant expression will not compile.  One enum value, evaluated once
 * wherever this header is read.
 */
enum {
	Ospreydata_layout_ok =
		/* a server's data area */
		1/(Odarm + Odarmlen <= Odtaken)
		+ 1/(Odtaken + Odtakenlen <= Odmig)
		+ 1/(Odmig + Odmiglen <= Odticket)
		+ 1/(Odticket + Odticketlen <= Odticketcliff)
		+ 1/(Odticketcliff + Odticketclifflen <= Ospreyblkoff)
		+ 1/(Ospreyblkoff + 128 <= Ospreynetoff)
		+ 1/(Ospreynetoff + 128 <= Ospreyblkring)
		+ 1/(Ospreyblkring + 1024 <= Odmigrx)
		/* a legacy container's data area */
		+ 1/(Odbuddyarg + Odbuddyarglen <= Odbuddyname)
		+ 1/(Odbuddyname + Odbuddynamelen <= Odbuddydata)
		/* a client's data area */
		+ 1/(Odt9 + Odt9len <= Odr9)
		+ 1/(Odr9 + Odr9len <= Odexecname)
		/* the input containers */
		+ 1/(Odkbd + Odkbdlen <= Odmouse),
};

#endif
