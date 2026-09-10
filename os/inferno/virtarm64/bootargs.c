#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

/*
 * The configuration this board is given, and where it comes from.
 *
 * On the PC the loader leaves plan9.ini's lines at a fixed low
 * address, CONFADDR, and os/inferno/pc/bootargs.c parses them there.
 * There is no low memory on this board -- RAM starts at KTZERO, where
 * the kernel itself is linked -- so os/inferno/boot/efi/aa64.s's jump()
 * passes the block's address in x1 instead, which the AArch64 Linux
 * boot protocol reserves as zero and QEMU's -kernel path therefore
 * leaves zero.  A boot with no loader sees confptr == 0 and gets an
 * empty configuration, which is what this board had before.
 *
 * The block lives in the loader's own memory, which the kernel is free
 * to allocate over, so bootargsinit() copies it before anything else
 * runs.  main() calls it first, immediately after zeroing bss.
 */
enum {
	MAXCONF		= 64,
	BOOTARGSLEN	= 4096-0x200-64,	/* as os/inferno/boot/efi/sub.c has it */
};

static char *confname[MAXCONF];
static char *confval[MAXCONF];
static int nconf;
static char confbuf[BOOTARGSLEN];

void
bootargsinit(void)
{
	extern uintptr confptr;		/* l.s: x1 at entry */
	int i, j, n;
	char *cp, *line[MAXCONF], *p, *q;

	if(confptr == 0)
		return;
	memmove(confbuf, (char*)confptr, sizeof(confbuf)-1);
	confbuf[sizeof(confbuf)-1] = 0;

	/*
	 * Strip out '\r', change '\t' -> ' '.
	 */
	cp = confbuf;
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
	return nil;
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

/*
 * The boot configuration, abbreviated.  *e820 is a single value some
 * six hundred characters long on a UEFI machine and longer on a real
 * one, and printing it whole pushed everything else off a 80-column
 * console for no gain: archmemreport() prints the same map parsed, one
 * run to a line, which is the form anyone reading it wants.
 */
void
showconf(void)
{
	int i, n;

	print("Boot configuration\n");
	for(i = 0; i < nconf; i++){
		n = strlen(confval[i]);
		if(n > 72)
			print("	%s=%.72s... (%d bytes)\n", confname[i], confval[i], n);
		else
			print("	%s=%s\n", confname[i], confval[i]);
	}
}
