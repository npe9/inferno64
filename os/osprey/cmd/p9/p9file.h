/* the file-descriptor layer (p9file.c): open/read/write/close by fd */
int	p9open(char *name, int mode);
void	p9close(int fd);
long	p9read(int fd, void *buf, long n);
long	p9write(int fd, void *buf, long n);
vlong	p9seek(int fd, vlong off, int type);	/* 0 set, 1 cur, 2 end */
int	p9stat(int fd, Dir *d, uchar *buf, int nbuf);	/* fill *d; strings in buf */
int	p9create(char *name, int mode, ulong perm);	/* create a file, return fd */
int	p9bind(char *name, char *old, int flag);	/* bind name onto old */
