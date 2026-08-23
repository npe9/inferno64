/*
 * Softscreen + ramfb for QEMU -M virt.
 */
typedef struct Cursor Cursor;

enum {
	CURSWID = 16,
	CURSHGT = 16,
};

struct Cursor
{
	Point	offset;
	uchar	clr[CURSWID/BI2BY*CURSHGT];
	uchar	set[CURSWID/BI2BY*CURSHGT];
};

extern Memimage*	gscreen;

extern Memdata*	attachscreen(Rectangle*, ulong*, int*, int*, int*);
extern void	flushmemscreen(Rectangle);
extern void	cursoron(void);
extern void	cursoroff(void);
extern void	setcursor(Cursor*);
extern void	cursorenable(void);
extern void	cursordisable(void);
extern Point	mousexy(void);
extern int	hwdraw(Memdrawparam*);
extern void	screeninit(void);
extern void	screenrotate(int);

extern int	ishwimage(Memimage*);

/* os/port/swcursor.c — overlay cursor (composed in flushmemscreen) */
extern void	swcursorhide(int);
extern void	swcursoravoid(Rectangle);
extern void	swcursordraw(Point);
extern void	swcursorload(Cursor*);
extern Cursor*	swcursorget(void);
extern void	swcursorinit(void);
extern void	swcursorwant(void);
extern void	swcursormarked(Point);
extern int	swcursorneeded(void);
extern void	swcursorsync(void);
extern void	swcursordounlock(void);
extern void	cursorcompose(void);
extern void	screenstats(void);

extern u32	blanktime;
extern QLock	drawlock;
