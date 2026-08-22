/*
 * Host-resident objects shared between capability devices. See hostobj.c for
 * why this is one registry rather than one per device.
 */
typedef struct Hostobj Hostobj;

struct Hostobj
{
	int	id;
	int	ref;
	char	type[16];	/* "pixbuf", "tensor", "bytes", ... */
	int	w, h;		/* image-like objects; 0 otherwise */
	char	fmt[16];	/* "bgra8", "nv12", "f32", ... */

	void*	aux;		/* the host object itself, opaque here */
	void	(*freeaux)(void*);

	void*	data;		/* bytes, when the producer can materialise them */
	uintptr	len;
};

extern Hostobj*	hostobjnew(char *type, void *aux, void (*freeaux)(void*), uintptr len);
extern Hostobj*	hostobjget(int id);		/* takes a reference */
extern void	hostobjput(Hostobj*);		/* drops one */
extern long	hostobjbytes(Hostobj*, void*, long, vlong);
extern int	hostobjlist(int *ids, int max);
extern Hostobj*	hostobjslot(int);	/* referenced, or nil for an empty slot */
extern int	hostobjnslot(void);
