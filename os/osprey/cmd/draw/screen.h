/* the "screen" the draw device draws onto - here the frame buffer the
 * microkernel exposes.  attachscreen hands back the exposed segment as a
 * Memdata, so the screen image's pixels ARE the frame buffer and draws
 * land on it directly; flushmemscreen is then nothing to do. */
extern Memdata*	attachscreen(Rectangle*, ulong *chan, int *depth, int *width, int *softscreen);
extern void	flushmemscreen(Rectangle);
extern void	mouseresize(void);
extern void	getcolor(ulong, ulong*, ulong*, ulong*);
extern int	setcolor(ulong, ulong, ulong, ulong);
extern void	blankscreen(int);
extern int	ishwimage(Memimage*);
