#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

#define	MAXCONF 64
static char *confname[MAXCONF];
static char *confval[MAXCONF];
static int nconf;

/* screen.c */
extern char* rgbmask2chan(char *buf, int depth, u32 rm, u32 gm, u32 bm);

/* vgavesa.c */
extern char* vesabootscreenconf(char*, char*, uchar*);

static void
multibootargs(void)
{
	extern ulong multibootptr;
	ulong *multiboot;
	char *cp, *ep, *s;
	ulong *m, l;
	int i, n;

	if(multibootptr == 0 || multibootptr >= MemMin)
		return;

	multiboot = (ulong*)KADDR(multibootptr);

	cp = BOOTARGS;
	ep = cp + BOOTARGSLEN-1;

	/* memory map */
	if((multiboot[0] & (1<<6)) != 0 && (l = multiboot[11]) >= 24){
		cp = seprint(cp, ep, "*e820=");
		m = KADDR(multiboot[12]);
		while(m[0] >= 20 && m[0]+4 <= l){
			uvlong base, size;
			m++;
			base = ((uvlong)m[0] | (uvlong)m[1]<<32);
			size = ((uvlong)m[2] | (uvlong)m[3]<<32);
			cp = seprint(cp, ep, "%.1lux %.16llux %.16llux ",
				m[4] & 0xF, base, base+size);
			l -= m[-1]+4;
			m = (ulong*)((uintptr)m + m[-1]);
		}
		cp[-1] = '\n';
	}

	if((multiboot[0] & (1<<12)) != 0 && multiboot[22] != 0){	/* framebuffer */
		uchar *p = (uchar*)multiboot + 112;
		int depth = multiboot[27] & 0xFF;
		char chan[32];

		switch((multiboot[27]>>8) & 0xFF){
		case 0:
			snprint(chan, sizeof chan, "m%d", depth);
			if(0){
		case 1:
			rgbmask2chan(chan, depth,
				(1UL<<p[1])-1 << p[0],
				(1UL<<p[3])-1 << p[2],
				(1UL<<p[5])-1 << p[4]);
			}
			cp = seprint(cp, ep, "*bootscreen=%dx%dx%d %s %#lux\n",
				(int)multiboot[24]*8 / depth,
				(int)multiboot[26],
				depth,
				chan,
				multiboot[22]);
		}
	} else
	if((multiboot[0] & (1<<11)) != 0 && multiboot[19] != 0)		/* vbe mode info */
		cp = vesabootscreenconf(cp, ep, KADDR(multiboot[19]));

	/* plan9.ini passed as the first module */
	if((multiboot[0] & (1<<3)) != 0 && multiboot[5] > 0 && multiboot[6] != 0){
		m = KADDR(multiboot[6]);
		s = (char*)KADDR(m[0]);
		if(m[1] > m[0]){
			n = utfnlen(s, m[1] - m[0]);
			if(n > 0)
				cp = seprint(cp, ep, "%.*s\n", n, s);
		}
	}

	/* command line */
	if((multiboot[0] & (1<<2)) != 0 && multiboot[4] != 0){
		n = tokenize(KADDR(multiboot[4]), confval, MAXCONF);
		for(i=0; i<n; i++)
			cp = seprint(cp, ep, "%s\n", confval[i]);
	}

	*cp = 0;
}

/*
 * struct hvm_start_info, from the x86/HVM direct boot ABI: what a PVH
 * loader leaves for the kernel in place of a multiboot information
 * structure.  Read as 32-bit words because the two 64-bit fields this
 * wants are the only ones that need joining, and l.s records the
 * pointer as a physical address in pvhptr.
 *
 *	 0 magic	 4 version	 8 flags	12 nr_modules
 *	16 modlist	24 cmdline	32 rsdp		40 memmap
 *	48 memmap_entries
 *
 * A memory-map entry is addr, size, type, reserved: 8+8+4+4 bytes, and
 * the type is already an E820 type, which is what *e820= carries.
 */
enum {
	Pvhmagic	= 0x336ec578,	/* xEn3 */
};

static void
pvhargs(void)
{
	extern ulong pvhptr;
	u32int *si, nment, i;
	uvlong cmdline, rsdp, memmap, base, end, pbase, pend;
	uchar *m;
	char *cp, *ep;
	int type, ptype;

	if(pvhptr == 0 || pvhptr >= MemMin)
		return;
	si = (u32int*)KADDR((uintptr)pvhptr);
	if(si[0] != Pvhmagic)
		return;

	cmdline = (uvlong)si[6] | (uvlong)si[7]<<32;
	rsdp = (uvlong)si[8] | (uvlong)si[9]<<32;
	memmap = (uvlong)si[10] | (uvlong)si[11]<<32;
	nment = si[1] >= 1 ? si[12] : 0;

	cp = BOOTARGS;
	ep = cp + BOOTARGSLEN-1;

	/*
	 * Adjacent entries of the same type become one, and the line
	 * stops at an entry boundary if it will not all fit: the same
	 * two reasons os/inferno/boot/efi/efi.c's memconf does it, since
	 * BOOTARGSLEN is the same 3520 bytes here and a hypervisor's map
	 * is no smaller than a firmware's.
	 */
	ptype = 0;
	pbase = pend = 0;
	for(i = 0; i <= nment; i++){
		if(i < nment){
			m = (uchar*)KADDR((uintptr)memmap) + i*24;
			base = *(uvlong*)(m+0);
			end = base + *(uvlong*)(m+8);
			type = *(u32int*)(m+16);
			if(type <= 0 || base >= end)
				continue;
			if(type == ptype && base == pend){
				pend = end;
				continue;
			}
		} else
			type = base = end = 0;

		if(ptype != 0){
			if(cp + 40 >= ep)
				break;
			if(cp == BOOTARGS)
				cp = seprint(cp, ep, "*e820=");
			cp = seprint(cp, ep, "%.1ux %.16llux %.16llux ",
				ptype, pbase, pend);
		}
		if(i >= nment)
			break;
		ptype = type;
		pbase = base;
		pend = end;
	}
	if(cp > BOOTARGS)
		cp[-1] = '\n';

	/*
	 * The RSDP address, because a PVH guest has no BIOS area to scan
	 * for it -- os/inferno/pc/archacpi.c reads *acpi when it is there.
	 */
	if(rsdp != 0)
		cp = seprint(cp, ep, "*acpi=%#llux\n", rsdp);

	/* the command line, one configuration line per word */
	if(cmdline != 0){
		int nc, j;

		nc = tokenize(KADDR((uintptr)cmdline), confval, MAXCONF);
		for(j = 0; j < nc; j++)
			cp = seprint(cp, ep, "%s\n", confval[j]);
	}

	*cp = 0;
}

void
bootargsinit(void)
{
	int i, j, n;
	char *cp, *line[MAXCONF], *p, *q;

	pvhargs();
	multibootargs();

	/*
	 *  parse configuration args from dos file plan9.ini
	 */
	cp = BOOTARGS;	/* where b.com leaves its config */
	cp[BOOTARGSLEN-1] = 0;

	/*
	 * Strip out '\r', change '\t' -> ' '.
	 */
	p = cp;
	for(q = cp; *q; q++){
		if(*q == '\r')
			continue;
		if(*q == '\t')
			*q = ' ';
		*p++ = *q;
	}
	*p = 0;

	n = getfields(cp, line, MAXCONF, 1, "\n");
	for(i = 0; i < n; i++){
		if(*line[i] == '#')
			continue;
		cp = strchr(line[i], '=');
		if(cp == nil)
			continue;
		*cp++ = '\0';
		for(j = 0; j < nconf; j++){
			if(cistrcmp(confname[j], line[i]) == 0)
				break;
		}
		confname[j] = line[i];
		confval[j] = cp;
		if(j == nconf)
			nconf++;
	}
}

char*
getconf(char *name)
{
	int i;

	for(i = 0; i < nconf; i++)
		if(cistrcmp(confname[i], name) == 0)
			return confval[i];
	return 0;
}

void
setconfenv(void)
{
	int i;

	for(i = 0; i < nconf; i++){
		if(confname[i][0] != '*')
			ksetenv(confname[i], confval[i], 0);
		ksetenv(confname[i], confval[i], 1);
	}
}

void
writeconf(void)
{
	char *p, *q;
	int n;

	p = getconfenv();
	if(waserror()) {
		free(p);
		nexterror();
	}

	/* convert to name=value\n format */
	for(q=p; *q; q++) {
		q += strlen(q);
		*q = '=';
		q += strlen(q);
		*q = '\n';
	}
	n = q - p + 1;
	if(n >= BOOTARGSLEN)
		error("kernel configuration too large");
	memmove(BOOTARGS, p, n);
	memset(BOOTLINE, 0, BOOTLINELEN);
	poperror();
	free(p);
}

void
showconf(void)
{
	int i;

	print("Boot configuration\n");
	for(i = 0; i < nconf; i++){
		print("	%s=%s\n", confname[i], confval[i]);
	}
}
