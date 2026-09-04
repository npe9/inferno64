/* the file-descriptor layer (p9file.c): open/read/write/close by fd */
int	p9open(char *name, int mode);
void	p9close(int fd);
long	p9read(int fd, void *buf, long n);
long	p9write(int fd, void *buf, long n);
vlong	p9seek(int fd, vlong off, int type);	/* 0 set, 1 cur, 2 end */
int	p9stat(int fd, Dir *d, uchar *buf, int nbuf);	/* fill *d; strings in buf */
int	p9create(char *name, int mode, ulong perm);	/* create a file, return fd */
int	p9remove(char *name);				/* remove name; 0, or -1 */
long	p9fstatraw(int fd, uchar *buf, int nbuf);	/* raw stat message of fd, byte count or -1 */
long	p9statraw(char *name, uchar *buf, int nbuf);	/* raw stat message of a named file */
int	p9bind(char *name, char *old, int flag);	/* bind name onto old */
int	p9dup(int oldfd);			/* duplicate a descriptor onto a new one */
