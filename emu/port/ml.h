/*
 * ml(3)'s backend interface.
 *
 * A backend is seven functions. Every one of them reports failure by returning
 * -1 (or nil) and filling err, so the device never has to guess why something
 * did not work: the message the backend gives is what reaches the caller's %r,
 * which is the only way a wrong model or a wrong input size is diagnosable
 * from Limbo.
 *
 * There are two, and which one runs a model is decided when it is loaded.
 *
 *	soft	this system's own arithmetic, in mlsoft.c. Always present -
 *		it needs nothing but libmath, which every configuration
 *		already links - and it is the whole of ml(3) on a machine with
 *		no accelerator and on native Inferno, where there is no host
 *		to ask.
 *
 *	host	the host's inference framework, in mlonnx.c, which talks to
 *		mlsrv over a pipe. Present only where there is such a host, so
 *		mlhostbe is nil on native and on any emu built without it.
 *
 * Preferring the host where there is one and falling back to soft where there
 * is not is the default, and it is what makes the same Limbo program work on
 * both. "backend soft" pins it, which is how the two are compared.
 */

typedef struct Mlbackend Mlbackend;

struct Mlbackend
{
	char	*name;
	void*	(*open)(uchar *spec, int nspec, char *units, char *err, int nerr);
	void	(*close)(void *m);
	int	(*info)(void *m, char *buf, int nbuf);
	int	(*setinput)(void *m, char *name, uchar *b, int n, char *err, int nerr);
	int	(*run)(void *m, char *err, int nerr);
	int	(*getoutput)(void *m, char *name, uchar *b, int nbuf, char *err, int nerr);
	int	(*setshape)(void *m, char *name, char **dims, int ndims, char *err, int nerr);
};

extern Mlbackend	*mlhostbe;	/* nil where the host has nothing to offer */
extern Mlbackend	mlsoftbe;	/* always here */
