#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"

/*
 * A place for a board to write down what it measured about itself, at
 * #P/cal.
 *
 * doc/radio-plan.ms item 8.  /lib/radio holds this board's crystal
 * correction, RSSI offset, carrier sense threshold and callsign, keyed
 * by the serial number at #P/uid -- and it is in devroot, served
 * read-only out of flash, so a new measurement means an edit on a host
 * and a flash cycle.  radiocal(1) measures and prints; nothing writes it
 * down.  This is what writes it down.
 *
 * AN APPEND-ONLY LOG IN FLASH THAT IS NEVER ERASED, and the reason is
 * that this part has no spare sector.  Measured against RM0090 table 5:
 * the image occupies sectors 0 to 9 entirely and ends inside sector 10,
 * and sector 11 holds the HID bootloader, which is the only way back
 * into the board.  What is spare is the tail of sector 10.
 *
 * It has never been written, so it is still erased -- and flash
 * programming turns ones into zeroes, so appending to erased flash needs
 * no erase at all.  That removes the whole of what makes a flash store
 * hard: no sector-erase driver, no wear levelling, and no window in
 * which a power cut leaves the store erased rather than merely old.  The
 * only thing that erases this region is a reflash, which rewrites
 * /lib/radio anyway.
 *
 * WHERE THE END IS.  The first 0xff byte.  The content is attrdb(6)
 * text, which never contains one, and erased flash is all ones -- so the
 * log needs no header, no length field and no superblock, and a reader
 * that knows nothing about this device can tell written from unwritten
 * by looking.  A record is whatever was written; a reader takes the last
 * entry for a uid, which is what makes this a log rather than a file.
 *
 * WHAT IT REFUSES.  A write that would run past the end, because
 * silently truncating a calibration is worse than not storing it.  And
 * there is no erase and no rewrite: a value here can be superseded by
 * appending another, which is the only operation erased flash supports
 * without one.
 *
 * PROGRAMMING WHILE EXECUTING FROM FLASH is allowed on this part and is
 * what this does.  RM0090 3.5.1: "any attempt to read the Flash memory
 * while it is being written or erased causes the bus to stall", and the
 * read completes once the operation has.  So the CPU stalls through each
 * byte rather than faulting, and no RAM trampoline is needed.  A byte
 * takes tens of microseconds, so this is done at splhi with the lock
 * held and a record is a few milliseconds of stalled bus -- which is why
 * it is a ctl-style write of a whole record and not a byte at a time
 * from a shell.
 */

enum {
	/* FLASH_CR, RM0090 3.9.7 */
	Crpg		= 1<<0,		/* program */
	Crpsize		= 3<<8,
	Crpsizebyte	= 0<<8,
	Crlock		= 1<<31,

	/* FLASH_SR, RM0090 3.9.6 */
	Sreop		= 1<<0,
	Sroperr		= 1<<1,
	Srwrperr	= 1<<4,
	Srpgaerr	= 1<<5,
	Srpgperr	= 1<<6,
	Srpgserr	= 1<<7,
	Srbsy		= 1<<16,
	Srerrors	= Sroperr|Srwrperr|Srpgaerr|Srpgperr|Srpgserr,

	Busywait	= 200000,	/* turns of a loop, not a time */
};

static Lock callock;

/*
 * How much of the store has been written: up to the first erased byte.
 * Called with the lock held, or on a path where a racing append does
 * not matter because it can only make the answer larger.
 */
static int
calused(void)
{
	uchar *p;
	int i;

	p = (uchar*)CALBASE;
	for(i = 0; i < CALSIZE; i++)
		if(p[i] == 0xff)
			break;
	return i;
}

static int
flashwait(void)
{
	int i, sr;

	for(i = 0; i < Busywait; i++)
		if((*(volatile u32*)FLASH_SR & Srbsy) == 0)
			break;
	sr = *(volatile u32*)FLASH_SR;
	if(sr & Srbsy)
		return -1;
	return sr;
}

/*
 * Append n bytes.  Returns how many went in, or -1 with the reason in
 * up->errstr via error().
 */
static int
calappend(uchar *a, int n)
{
	int used, i, sr;
	volatile u32 *cr;
	uchar *p;

	cr = (volatile u32*)FLASH_CR;
	used = calused();
	if(n <= 0)
		return 0;
	if(used + n > CALSIZE){
		snprint(up->genbuf, sizeof up->genbuf,
			"cal: %d bytes written of %d, %d more will not fit",
			used, CALSIZE, n);
		error(up->genbuf);
	}
	p = (uchar*)CALBASE + used;

	ilock(&callock);
	if(waserror()){
		*cr &= ~Crpg;
		*cr |= Crlock;
		iunlock(&callock);
		nexterror();
	}

	/* unlock, and say so rather than writing into a locked flash */
	if(*cr & Crlock){
		*(volatile u32*)FLASH_KEYR = FLASH_KEY1;
		*(volatile u32*)FLASH_KEYR = FLASH_KEY2;
	}
	if(*cr & Crlock)
		error("cal: flash will not unlock");
	if(flashwait() < 0)
		error("cal: flash busy before programming");
	/* clear whatever a previous operation left */
	*(volatile u32*)FLASH_SR = Srerrors|Sreop;

	*cr = (*cr & ~Crpsize) | Crpsizebyte;
	*cr |= Crpg;
	coherence();
	for(i = 0; i < n; i++){
		/*
		 * A byte that is already what it should be is skipped,
		 * and one that cannot be made so is an error rather than
		 * a silent difference.  Programming can only clear bits:
		 * writing 0x41 over 0xff works and over 0x40 does not,
		 * and the part reports PGPERR for the second.  This
		 * cannot happen on a store that is only ever appended
		 * to, which is why it is an error and not a case.
		 */
		if(p[i] == a[i])
			continue;
		if((p[i] & a[i]) != a[i]){
			*cr &= ~Crpg;
			*cr |= Crlock;
			snprint(up->genbuf, sizeof up->genbuf,
				"cal: 0x%.2ux at offset %d cannot become "
				"0x%.2ux; flash only clears bits",
				p[i], used+i, a[i]);
			error(up->genbuf);
		}
		p[i] = a[i];
		coherence();
		sr = flashwait();
		if(sr < 0){
			*cr &= ~Crpg;
			*cr |= Crlock;
			error("cal: flash stayed busy");
		}
		if(sr & Srerrors){
			*(volatile u32*)FLASH_SR = Srerrors|Sreop;
			*cr &= ~Crpg;
			*cr |= Crlock;
			snprint(up->genbuf, sizeof up->genbuf,
				"cal: FLASH_SR 0x%.8ux at offset %d",
				sr, used+i);
			error(up->genbuf);
		}
	}
	*cr &= ~Crpg;
	*cr |= Crlock;
	poperror();
	iunlock(&callock);

	/*
	 * And read it back, because a flash write that reports success
	 * and did not take is exactly the class of thing this bench has
	 * spent a day on.  The compare is against the caller's bytes and
	 * not against what was just read from the same place.
	 */
	for(i = 0; i < n; i++)
		if(p[i] != a[i]){
			snprint(up->genbuf, sizeof up->genbuf,
				"cal: wrote 0x%.2ux at offset %d and it "
				"reads 0x%.2ux", a[i], used+i, p[i]);
			error(up->genbuf);
		}
	return n;
}

static s32
calread(Chan*, void *a, s32 n, s64 offset)
{
	int used;

	used = calused();
	if(offset >= used)
		return 0;
	if(offset + n > used)
		n = used - offset;
	memmove(a, (uchar*)CALBASE + offset, n);
	return n;
}

static s32
calwrite(Chan*, void *a, s32 n, s64)
{
	return calappend(a, n);
}

/*
 * What the store is, at #P/calinfo, so that a program can ask how much
 * room is left without reading the whole thing and counting.
 */
static s32
calinforead(Chan*, void *a, s32 n, s64 offset)
{
	char buf[128];

	snprint(buf, sizeof buf,
		"base 0x%.8ux size %d used %d free %d\n",
		CALBASE, CALSIZE, calused(), CALSIZE - calused());
	return readstr(offset, a, n, buf);
}

void
calstm32f4link(void)
{
	addarchfile("cal", 0664, calread, calwrite);
	addarchfile("calinfo", 0444, calinforead, nil);
}
