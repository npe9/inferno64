/*
 * The ring transport: the p9 personality's link to a file server that is
 * another container across the microkernel message ring.  Implemented in
 * ring9p.c against the user headers (libc's segattach/sleep syscalls),
 * exposed here in plain types so dev9ploop.c - compiled against the
 * kernel headers - can call it without the two header worlds meeting.
 */
int	ring9p_init(void);			/* map this container's ring; 0 ok, -1 no */
long	ring9p_xfer(uchar *tmsg, long tn, uchar *rbuf, long rmax);	/* one 9P T/R exchange */
long	ring9p_frame(uchar *frame, long n, uchar *back, long backmax);	/* a frame to the peer container's stack (n may be 0: a poll), and one of its back */
int	ring9p_taketick(int sem);		/* ask the kernel for the clock on a semaphore of ours */
int	ring9p_waittick(int sem);		/* wait for one tick on it by select; 0 taken, -1 not */
