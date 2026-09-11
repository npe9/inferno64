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
extern uvlong memtop;			/* efi.c, from the firmware's map */
/* Values consumed by the mode-switch stub after ExitBootServices. */
extern void *jumpentry;
void *jumpargs;
#ifdef AA64
extern void *dtb(void);			/* aa64boot.c */
extern int claim(void*, uintptr);
extern void cachewb(void*, void*);	/* aa64.s */
#endif
static char *confend;

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

char*
bootkern(void *f)
{
	uchar *e, *d, *t;
	ulong n;
	Exec ex;

	if(readn(f, &ex, sizeof(ex)) != sizeof(ex))
		return "bad header";

	e = (uchar*)(beswal(ex.entry) & ~0xF0000000UL);
	switch(beswal(ex.magic)){
	case S_MAGIC:
	case R_MAGIC:
		if(readn(f, &e, 8) != 8)
			goto Error;
#ifdef AA64
		/*
		 * The whole address, not the low twenty-eight bits of it.
		 * Masking is right for a pc kernel, which is linked in the
		 * kernel segment and loaded at the physical address under
		 * it; an arm64 kernel here links at 0x40200000, which is
		 * already physical, and masking turns it into 0x00200000 --
		 * memory an arm64 machine does not have.
		 */
		e = (uchar*)beswall((uvlong)e);
#else
		/* load low address */
		e = (uchar*)(beswall((uvlong)e) & 0x0FFFFFFFUL);
#endif
		break;
	case I_MAGIC:
		break;
	default:
		return "bad magic";
	}

#ifdef AA64
	/*
	 * Ask the firmware for the range before writing a byte of it.
	 * AllocateAddress asks for one address and takes no other, so a
	 * refusal means UEFI has that memory and the load would have
	 * corrupted it -- which, without this, is a thing found out after
	 * ExitBootServices, past the last point anything can be printed.
	 */
	n = PGROUND(beswal(ex.text)) + PGROUND(beswal(ex.data))
		+ PGROUND(beswal(ex.bss));
	if(claim(e, n) < 0)
		return "the firmware will not give up the kernel's address";
#endif

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

#ifdef AA64
	/*
	 * Last write to the image, so the last chance to get it out of
	 * the data cache: jump() runs with the cache off and the kernel
	 * reads itself from memory.
	 */
	cachewb(e, t);
#endif

	close(f);

	/* stop device */
	if(stop) (*stop)();

	print("boot\n");

#ifdef AA64
	/*
	 * No memconf(): its e820 map is a pc kernel's way of being told
	 * about memory and nothing on arm64 reads one.  What an arm64
	 * kernel does want is a device tree in x0, and UEFI has one to
	 * give only when the firmware published it -- so say which way it
	 * went while there is still a console to say it on.
	 */
	jumpargs = dtb();
	if(jumpargs == nil)
		print("no device tree from the firmware (acpi=off?)\n");
	jumpentry = e;
	/*
	 * For MK, which ExitBootServices() will not proceed without: it
	 * takes the key of the current memory map and refuses a stale
	 * one.  nil asks memconf() for the key and nothing else, which is
	 * what the x86 path does too when the configuration already
	 * carries an e820 list.
	 */
	memconf(nil);

	/*
	 * And one line the kernel can read it back out of.  virtarm64's
	 * archconfinit() sizes memory from the device tree when there is
	 * one and from mem.h's DRAMSIZE when there is not -- and on a
	 * firmware that publishes ACPI there is not, so a machine with
	 * more memory than DRAMSIZE loses the difference and one with
	 * less is claimed anyway.  The firmware's own map is the only
	 * authority left.
	 *
	 * One number, not the whole map: confinit() computes its page
	 * count from a single range starting at PHYSDRAM, so a top is
	 * all it can use.  A machine with holes in its memory needs the
	 * whole map and a confinit() that can take it.
	 */
	if(memtop != 0 && confend + 32 < BOOTARGS + BOOTARGSLEN){
		memmove(confend, "*memtop=0x", 10);
		confend += 10;
		confend = hexfmt(confend, 16, memtop);
		*confend++ = '\n';
		*confend = '\0';
	}
	unload();

	/*
	 * The configuration goes in x1.  It is the only way the kernel
	 * can be told the RSDP the firmware handed over, and on a machine
	 * that publishes ACPI rather than a device tree it is the only
	 * thing in this call that is not nil.
	 */
	jump(e, jumpargs, BOOTARGS);
#else
	memconf(findconf("*e820=")?nil:&confend);
	jumpentry = e;
	/* Osprey's entry records BX as the Multiboot pointer.  EFI has no
	 * Multiboot structure; configuration remains available at CONFADDR. */
	jumpargs = nil;
	unload();

	jump(e, BOOTARGS);
#endif

Error:
	return "i/o error";
}
