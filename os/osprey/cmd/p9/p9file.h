/* the file-descriptor layer (p9file.c): open/read/write/close by fd */
int	p9open(char *name, int mode);
void	p9close(int fd);
long	p9read(int fd, void *buf, long n);
long	p9write(int fd, void *buf, long n);
