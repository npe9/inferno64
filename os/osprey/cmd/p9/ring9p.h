/*
 * The ring transport: the p9 personality's link to a file server that is
 * another container across the microkernel message ring.  Implemented in
 * ring9p.c against the user headers (libc's segattach/sleep syscalls),
 * exposed here in plain types so dev9ploop.c - compiled against the
 * kernel headers - can call it without the two header worlds meeting.
 */
int	ring9p_init(void);			/* map this container's ring; 0 ok, -1 no */
long	ring9p_xfer(uchar *tmsg, long tn, uchar *rbuf, long rmax);	/* one 9P T/R exchange */
long	ring9p_frame(uchar *frame, long n, uchar *unused, long unused2);	/* a frame to the peer container's stack, staged in our packet buffer */
uchar*	ring9p_taken(long *len);		/* a frame the server put in our packet buffer, just taken off our output queue */
int	ring9p_taketick(int sem);		/* ask the kernel for the clock on a semaphore of ours */
int	ring9p_wait(int sem);			/* wait by select: 0 the tick, 1 a frame from the server, -1 neither */
long	ring9p_replyroom(void);	/* how many bytes of a container's data area an R-message may fill */
