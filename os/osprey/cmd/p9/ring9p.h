/*
 * The ring transport: the p9 personality's link to a file server that is
 * another container across the microkernel message ring.  Implemented in
 * ring9p.c against the user headers (libc's segattach/sleep syscalls),
 * exposed here in plain types so dev9ploop.c - compiled against the
 * kernel headers - can call it without the two header worlds meeting.
 */
int	ring9p_init(void);			/* map this container's ring; 0 ok, -1 no */
long	ring9p_xfer(uchar *tmsg, long tn, uchar *rbuf, long rmax);	/* one 9P T/R exchange */
