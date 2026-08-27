/*
 * kbd.c - a user-level keyboard driver for the full personality.
 *
 * The microkernel exposes the PS/2 keyboard scancode stream as the
 * physical segment "kbdring" (see ospreymouseexpose in devosprey.c): an
 * 8-byte write count then a ring of raw set-1 scancodes the IRQ1 handler
 * fills.  This program segattaches that page, tracks shift and control,
 * translates the scancodes through a US keymap into runes, and serves
 * /dev/kbd in the character form rio reads ("c" followed by the rune).
 * With it a window in rio takes keyboard input, the input path a user
 * program above the microkernel - no keyboard device in the kernel.
 */
#include <u.h>
#include <libc.h>
#include <fcall.h>
/* 9p.h needs Ref, which this environment's libc.h does not define */
typedef struct Ref Ref;
struct Ref {
	long	ref;
};
#include <9p.h>

enum {
	Kbdn	= 256,		/* ring capacity, matches the kernel */
};

static uchar	*ring;
static uvlong	rp;
static int	shift, ctl;

/* US scancode set 1: unshifted and shifted rune for each make code */
static Rune unshift[128] = {
[0x01] 0x1b,
[0x02] '1',[0x03] '2',[0x04] '3',[0x05] '4',[0x06] '5',[0x07] '6',
[0x08] '7',[0x09] '8',[0x0a] '9',[0x0b] '0',[0x0c] '-',[0x0d] '=',
[0x0e] '\b',[0x0f] '\t',
[0x10] 'q',[0x11] 'w',[0x12] 'e',[0x13] 'r',[0x14] 't',[0x15] 'y',
[0x16] 'u',[0x17] 'i',[0x18] 'o',[0x19] 'p',[0x1a] '[',[0x1b] ']',
[0x1c] '\n',
[0x1e] 'a',[0x1f] 's',[0x20] 'd',[0x21] 'f',[0x22] 'g',[0x23] 'h',
[0x24] 'j',[0x25] 'k',[0x26] 'l',[0x27] ';',[0x28] '\'',[0x29] '`',
[0x2b] '\\',
[0x2c] 'z',[0x2d] 'x',[0x2e] 'c',[0x2f] 'v',[0x30] 'b',[0x31] 'n',
[0x32] 'm',[0x33] ',',[0x34] '.',[0x35] '/',
[0x39] ' ',
};
static Rune shifted[128] = {
[0x01] 0x1b,
[0x02] '!',[0x03] '@',[0x04] '#',[0x05] '$',[0x06] '%',[0x07] '^',
[0x08] '&',[0x09] '*',[0x0a] '(',[0x0b] ')',[0x0c] '_',[0x0d] '+',
[0x0e] '\b',[0x0f] '\t',
[0x10] 'Q',[0x11] 'W',[0x12] 'E',[0x13] 'R',[0x14] 'T',[0x15] 'Y',
[0x16] 'U',[0x17] 'I',[0x18] 'O',[0x19] 'P',[0x1a] '{',[0x1b] '}',
[0x1c] '\n',
[0x1e] 'A',[0x1f] 'S',[0x20] 'D',[0x21] 'F',[0x22] 'G',[0x23] 'H',
[0x24] 'J',[0x25] 'K',[0x26] 'L',[0x27] ':',[0x28] '"',[0x29] '~',
[0x2b] '|',
[0x2c] 'Z',[0x2d] 'X',[0x2e] 'C',[0x2f] 'V',[0x30] 'B',[0x31] 'N',
[0x32] 'M',[0x33] '<',[0x34] '>',[0x35] '?',
[0x39] ' ',
};

static int
nextbyte(void)
{
	uvlong count;

	count = *(uvlong*)ring;
	if(rp >= count)
		return -1;
	if(count - rp > Kbdn)
		rp = count - Kbdn;
	return ring[8 + (rp++ % Kbdn)];
}

/* wait for the next character-producing keypress, return its rune */
static Rune
nextrune(void)
{
	int sc;
	Rune r;

	for(;;){
		sc = nextbyte();
		if(sc < 0){
			sleep(5);
			continue;
		}
		if(sc == 0xe0)			/* extended prefix: skip it */
			continue;
		if(sc & 0x80){			/* break code */
			sc &= 0x7f;
			if(sc == 0x2a || sc == 0x36)
				shift = 0;
			else if(sc == 0x1d)
				ctl = 0;
			continue;
		}
		if(sc == 0x2a || sc == 0x36){
			shift = 1;
			continue;
		}
		if(sc == 0x1d){
			ctl = 1;
			continue;
		}
		if(sc >= 128)
			continue;
		r = shift ? shifted[sc] : unshift[sc];
		if(r == 0)
			continue;
		if(ctl && r < 0x80){		/* control folds a letter to ^X */
			if(r >= 'a' && r <= 'z')
				r &= 0x1f;
			else if(r >= '@' && r <= '_')
				r &= 0x1f;
		}
		return r;
	}
}

static void
fsread(Req *r)
{
	char buf[UTFmax+2];
	Rune ru;
	int n;

	if(r->fid->file == nil || strcmp(r->fid->file->name, "kbd") != 0){
		respond(r, "not the kbd file");
		return;
	}
	ru = nextrune();
	buf[0] = 'c';
	n = 1 + runetochar(buf+1, &ru);
	buf[n++] = 0;			/* rio overwrites the last byte with 0 */
	if(n > r->ifcall.count)
		n = r->ifcall.count;
	memmove(r->ofcall.data, buf, n);
	r->ofcall.count = n;
	respond(r, nil);
}

static Srv kbdsrv = {
	.read = fsread,
};

void
usage(void)
{
	fprint(2, "usage: kbd [-m mtpt]\n");
	exits("usage");
}

void
main(int argc, char **argv)
{
	char *mtpt;
	void *v;

	mtpt = "/dev";
	ARGBEGIN{
	case 'm':
		mtpt = EARGF(usage());
	}ARGEND;
	USED(argc, argv);

	v = segattach(0, "kbdring", 0, Kbdn+16);
	if(v == (void*)-1)
		sysfatal("segattach kbdring: %r");
	ring = v;
	rp = *(uvlong*)ring;

	kbdsrv.tree = alloctree("glenda", "glenda", DMDIR|0555, nil);
	if(kbdsrv.tree == nil)
		sysfatal("alloctree: %r");
	if(createfile(kbdsrv.tree->root, "kbd", "glenda", 0666, nil) == nil)
		sysfatal("createfile: %r");
	postmountsrv(&kbdsrv, nil, mtpt, MBEFORE);
	exits(nil);
}
