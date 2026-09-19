#include <u.h>
#include <a.out.h>
#include "fns.h"
#include "mem.h"

char hex[] = "0123456789abcdef";

void
print(char *s)
{
	while(*s != 0){
		if(*s == '\n')
			putc('\r');
		putc(*s++);
	}
}

int
readn(void *f, void *data, int len)
{
	uchar *p, *e;

	p = data;
	e = p + len;
	while(p < e){
		if((len = read(f, p, e - p)) <= 0)
			break;
		p += len;
	}

	return p - (uchar*)data;
}

void
memmove(void *dst, void *src, int n)
{
	uchar *d = dst;
	uchar *s = src;

	if(d < s){
		while(n-- > 0)
			*d++ = *s++;
	} else if(d > s){
		s += n;
		d += n;
		while(n-- > 0)
			*--d = *--s;
	}
}

int
memcmp(void *src, void *dst, int n)
{
	uchar *d = dst;
	uchar *s = src;
	int r = 0;

	while(n-- > 0){
		r = *d++ - *s++;
		if(r != 0)
			break;
	}

	return r;
}

int
strlen(char *s)
{
	char *p = s;

	while(*p != '\0')
		p++;

	return p - s;
}

char*
strchr(char *s, int c)
{
	for(; *s != 0; s++)
		if(*s == c)
			return s;

	return nil;
}

void
memset(void *dst, int v, int n)
{
	uchar *d = dst;

	while(n > 0){
		*d++ = v;
		n--;
	}
}

static int
readline(void *f, char *buf)
{
	static char white[] = "\t ";
	char *p;

	p = buf;
	do{
		if(f == nil)
			putc('>');
		for(;;){
			if(f == nil){
				while((*p = getc()) == 0)
					;
				if(p == buf && (*p == '\b' || strchr(white, *p) != nil))
					continue;
				putc(*p);
				if(*p == '\r')
					putc('\n');
				else if(*p == '\b'){
					p--;
					putc(' ');
					putc('\b');
					continue;
				}
			}else if(read(f, p, 1) <= 0)
				return 0;
			if(strchr("\r\n", *p) != nil)
				break;
			if(p == buf && strchr(white, *p) != nil)
				continue;	/* whitespace on start of line */
			p++;
		}
		while(p > buf && strchr(white, p[-1]))
			p--;
	}while(p == buf);
	*p = 0;

	return p - buf;
}

static int
timeout(int ms)
{
	while(ms > 0){
		if(getc() != 0)
			return 1;
		usleep(100000);
		ms -= 100;
	}
	return 0;
}

#define BOOTLINE	confaddr
#define BOOTLINELEN	64
#define BOOTARGS	(confaddr+BOOTLINELEN)
#define	BOOTARGSLEN	(4096-0x200-BOOTLINELEN)

extern char *confaddr;
/* Values consumed by the mode-switch stub after ExitBootServices. */
extern void *jumpentry;
void *jumpargs;
static char *confend;
char *confmax;		/* end of the boot-argument area, for memconf() */

char*
findconf(char *s)
{
	char *p, *e;
	int n = strlen(s);
	for(p = BOOTARGS; p < confend; p = e+1){
		for(e = p; e < confend && *e != '\n'; e++){
			if(*e == '\0')
				return nil;
		}
		if(e - p >= n && memcmp(p, s, n) == 0)
			return p;
	}
	return nil;
}

static char*
getconf(char *s, char *buf)
{
	char *p, *e;

	if((p = findconf(s)) == nil)
		return nil;
	p += strlen(s);
	for(e = p; *e != '\n'; e++)
		;
	memmove(buf, p, e - p);
	buf[e - p] = '\0';
	return buf;
}

static int
delconf(char *s)
{
	char *p, *e;

	if((p = findconf(s)) == nil)
		return 0;
	for(e = p; *e != '\n'; e++)
		;
	e++;
	memmove(p, e, confend - e);
	confend -= e - p;
	*confend = '\0';
	return 1;
}

char*
configure(void *f, char *path)
{
	char *line, *kern, *s, *p;
	int inblock, nowait, n;
	static int once = 1;

	if(once){
		once = 0;
Clear:
		memset(BOOTLINE, 0, BOOTLINELEN);

		confend = BOOTARGS;
		confmax = BOOTARGS + BOOTARGSLEN;
		memset(confend, 0, BOOTARGSLEN);
		eficonfig(&confend);
	}
	nowait = 1;
	inblock = 0;
Loop:
	while(readline(f, line = confend+1) > 0){
		if(*line == 0 || strchr("#;=", *line) != nil)
			continue;
		if(*line == '['){
			inblock = memcmp("[common]", line, 8) != 0;
			continue;
		}
		if(memcmp("boot", line, 5) == 0){
			nowait=1;
			break;
		}
		if(memcmp("wait", line, 5) == 0){
			nowait=0;
			continue;
		}
		if(memcmp("show", line, 5) == 0){
			print(BOOTARGS);
			continue;
		}
		if(memcmp("clear", line, 5) == 0){
			if(line[5] == '\0'){
				print("ok\n");
				goto Clear;
			} else if(line[5] == ' ' && delconf(line+6))
				print("ok\n");
			continue;
		}
		if(inblock != 0 || (p = strchr(line, '=')) == nil)
			continue;
		*p++ = 0;
		delconf(line);
		s = confend;
		memmove(confend, line, n = strlen(line)); confend += n;
		*confend++ = '=';
		memmove(confend, p, n = strlen(p)); confend += n;
		*confend++ = '\n';
		*confend = 0;
		print(s);
	}
	kern = getconf("bootfile=", path);

	if(f != nil){
		close(f);
		f = nil;

		if(kern != nil && (nowait==0 || timeout(1000)))
			goto Loop;
	}

	if(kern == nil){
		print("no bootfile\n");
		goto Loop;
	}
	while((p = strchr(kern, '!')) != nil)
		kern = p+1;

	return kern;
}

static char*
numfmt(char *s, ulong b, ulong i, ulong a)
{
	char *r;

	if(i == 0){
		ulong v = a;
		while(v != 0){
			v /= b;
			i++;
		}
		if(i == 0)
			i = 1;
	}

	s += i;
	r = s;
	while(i > 0){
		*--s = hex[a % b];
		a /= b;
		i--;
	}
	return r;
}

char*
hexfmt(char *s, int i, uvlong a)
{
	if(i > 8 || i == 0 && (a>>32) != 0){
		s = numfmt(s, 16, i ? i-8 : 0, a>>32);
		i = 8;
	}
	return numfmt(s, 16, i, a);
}

char*
decfmt(char *s, int i, ulong a)
{
	return numfmt(s, 10, i, a);
}

static ulong
beswal(ulong l)
{
	uchar *p = (uchar*)&l;
	return (p[0]<<24) | (p[1]<<16) | (p[2]<<8) | p[3];
}

static uvlong
beswall(uvlong l)
{
	uchar *p = (uchar*)&l;
	return ((uvlong)p[0]<<56) | ((uvlong)p[1]<<48) | ((uvlong)p[2]<<40) | ((uvlong)p[3]<<32) | ((uvlong)p[4]<<24) | ((uvlong)p[5]<<16) | ((uvlong)p[6]<<8) | (uvlong)p[7];
}

static ushort
le2(uchar *p)
{
	return p[0] | p[1]<<8;
}

static ulong
le4(uchar *p)
{
	return p[0] | p[1]<<8 | p[2]<<16 | (ulong)p[3]<<24;
}

static uvlong
le8(uchar *p)
{
	return (uvlong)le4(p) | (uvlong)le4(p+4)<<32;
}

/*
 * Read and discard.  The file interface is open/read/close with no
 * seek, so a format whose parts are named by file offset can only be
 * loaded by reading forward -- which is enough, because the loaders
 * write their segments in ascending offset order.
 */
static int
skip(void *f, uvlong n)
{
	uchar buf[512];
	int m;

	while(n > 0){
		m = n > sizeof buf ? sizeof buf : (int)n;
		if(readn(f, buf, m) != m)
			return -1;
		n -= m;
	}
	return 0;
}

/*
 * Load an ELF64 kernel.  Every board in this tree but pc64 and armv7
 * links its kernel as ELF -- 7l -H7, jl and the rest -- because that
 * is what QEMU's -kernel takes, so a loader that reads only Plan 9
 * a.out can boot none of them.  hdr holds the first sizeof(Exec) bytes,
 * already read.
 *
 * Segments are loaded at their physical address, which is what the
 * boards' own linkers set and what a loader running with the MMU as the
 * firmware left it has to use.
 */
static char*
loadelf(void *f, uchar *hdr, uchar **entry)
{
	uchar eh[64], phs[16*56];
	uvlong off, fileoff, filesz, memsz, paddr;
	int i, phnum, phentsize;

	memmove(eh, hdr, sizeof(Exec));
	if(readn(f, eh+sizeof(Exec), sizeof eh - sizeof(Exec)) != sizeof eh - sizeof(Exec))
		return "bad ELF header";
	if(eh[4] != 2)
		return "not a 64-bit ELF";
	if(eh[5] != 1)
		return "not a little-endian ELF";
	if(le2(eh+16) != 2)
		return "not an ELF executable";
	phentsize = le2(eh+54);
	phnum = le2(eh+56);
	if(phentsize != 56)
		return "bad ELF program header size";
	if(phnum <= 0 || phnum > 16)
		return "bad ELF program header count";
	off = le8(eh+32);
	if(off < sizeof eh || skip(f, off - sizeof eh) < 0)
		return "i/o error";
	if(readn(f, phs, phnum*phentsize) != phnum*phentsize)
		return "i/o error";
	off += phnum*phentsize;

	for(i = 0; i < phnum; i++){
		uchar *p = phs + i*phentsize;

		if(le4(p) != 1)			/* PT_LOAD */
			continue;
		fileoff = le8(p+8);
		paddr = le8(p+24);		/* p_paddr */
		if(paddr == 0)
			paddr = le8(p+16);	/* p_vaddr, when there is no separate physical */
		filesz = le8(p+32);
		memsz = le8(p+40);
		if(fileoff < off)
			return "ELF segments out of order";
		if(skip(f, fileoff - off) < 0)
			return "i/o error";
		off = fileoff;
		if(filesz > 0){
			if(readn(f, (uchar*)paddr, (int)filesz) != (int)filesz)
				return "i/o error";
			off += filesz;
		}
		if(memsz > filesz)
			memset((uchar*)(paddr+filesz), 0, (int)(memsz - filesz));
	}
	*entry = (uchar*)le8(eh+24);
	return nil;
}

char*
bootkern(void *f)
{
	uchar *e, *d, *t;
	ulong n;
	Exec ex;
	char *err;

	if(readn(f, &ex, sizeof(ex)) != sizeof(ex))
		return "bad header";

	if(memcmp(&ex, "\177ELF", 4) == 0){
		if((err = loadelf(f, (uchar*)&ex, &e)) != nil)
			return err;
		goto Loaded;
	}

	e = (uchar*)(beswal(ex.entry) & ~0xF0000000UL);
	switch(beswal(ex.magic)){
	case S_MAGIC:
		if(readn(f, &e, 8) != 8)
			goto Error;
		/* load low address */
		e = (uchar*)(beswall((uvlong)e) & 0x0FFFFFFFUL);
		break;
	case R_MAGIC:
		if(readn(f, &e, 8) != 8)
			goto Error;
		/*
		 * No masking.  An arm64 kernel here is linked at the
		 * physical address it runs at -- 0x40000000 for
		 * virtarm64 -- and the 28-bit mask that turns a
		 * high-mapped amd64 entry into its low physical alias
		 * gives 0 for it.
		 */
		e = (uchar*)beswall((uvlong)e);
		break;
	case I_MAGIC:
		break;
	default:
		return "bad magic";
	}

	t = e;
	n = beswal(ex.text);
	if(readn(f, t, n) != n)
		goto Error;
	t += n;
	d = (uchar*)PGROUND((uintptr)t);
	memset(t, 0, d - t);
	n = beswal(ex.data);
	if(readn(f, d, n) != n)
		goto Error;
	d += n;
	t = (uchar*)PGROUND((uintptr)d);
	t += PGROUND(beswal(ex.bss));
	memset(d, 0, t - d);

Loaded:
	close(f);

	/* stop device */
	if(stop) (*stop)();

	print("boot\n");

	memconf(findconf("*e820=")?nil:&confend);
	jumpentry = e;
	/* Osprey's entry records BX as the Multiboot pointer.  EFI has no
	 * Multiboot structure; configuration remains available at CONFADDR. */
	jumpargs = nil;
	unload();

	jump(e, BOOTARGS);

Error:
	return "i/o error";
}
