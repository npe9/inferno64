#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"

/*
 * The STM32F4's analogue to digital converter, as a file under #P.
 *
 * A mikroBUS socket's AN pin is the one line on it that carries a
 * number rather than a protocol, and on a flight computer it is what a
 * battery, a current shunt or a sun sensor is on.  On a clicker 2 it
 * is PA2 for socket 1 and PA3 for socket 2, which are ADC123_IN2 and
 * ADC123_IN3.  The part's own three internal channels are here as
 * well: the temperature sensor on IN16, the internal reference on IN17
 * and the backup battery through a divider on IN18.  They need no pin
 * and no click, so they are the part of this that works on any F407.
 *
 * Reading /dev/adc converts each of the five, in one pass, and gives a
 * line per channel:
 *
 *	an1 438 352
 *	an2 0 0
 *	temp 944 760 25.0
 *	vref 1516 1221
 *	vbat 2045 1647 3294
 *
 * The raw count first, because that is what the part actually said,
 * then millivolts, then for the two channels where more can be said,
 * the thing being measured: degrees for the temperature sensor and the
 * battery's own millivolts for VBAT, which reaches the converter
 * through an internal divider.
 *
 * That is a real board's reading.  an2 is zero because mikroBUS 2's AN
 * is the click's GPIO0 and a CC1120 is sitting in that socket driving
 * it low -- the pin is an output belonging to something else, which is
 * what an analogue input on a socket with a part in it looks like.
 * an1 is an empty socket's floating pin and means nothing.  vref at
 * 1221mV against the 1.21V the datasheet gives says VREF+ is 3.27V, so
 * the 3300 below is good to within a percent.
 *
 * The millivolts assume VREF+ is 3.3V, which is what a clicker 2 ties
 * it to, and the temperature uses the datasheet's typical V25 of 760mV
 * and slope of 2.5mV per degree.  Neither is calibrated: an F407 has
 * no factory temperature constants in its flash the way an F0 or an L4
 * does, so a reading here is worth a degree or two and not better.
 * VREFINT is the honest way round that -- 1.21V typical against the
 * count it reads gives the true VREF+ -- and is why it is in the file.
 *
 * Under qemu none of this is a voltage.  hw/adc/stm32f2xx_adc.c
 * invents a value that carries the converted channel in its top bits
 * and a counter in the rest, so what a reading there shows is that the
 * sequence ran and converted the channel it meant to, which is the
 * part that can be got wrong in software.  See tools/qemu-patches/0047.
 */

enum {
	/* RM0090 13.13, ADC1 */
	Sr	= 0x00/4,
	  Eoc	= 1<<1,
	  Strt	= 1<<4,
	  Ovr	= 1<<5,
	Cr1	= 0x04/4,
	Cr2	= 0x08/4,
	  Adon	= 1<<0,
	  Cont	= 1<<1,
	  Swstart = 1<<30,
	Smpr1	= 0x0c/4,		/* channels 10 to 18 */
	Smpr2	= 0x10/4,		/* channels 0 to 9 */
	Sqr1	= 0x2c/4,
	Sqr2	= 0x30/4,
	Sqr3	= 0x34/4,
	Dr	= 0x4c/4,

	/* the common block, one for all three converters */
	Ccr	= 0x04/4,
	  Adcpre4 = 1<<16,		/* PCLK2 divided by four */
	  Vbate	= 1<<22,
	  Tsvrefe = 1<<23,

	Full	= 4095,			/* 12 bit */
	Vrefmv	= 3300,			/* VREF+ on a clicker 2 */
	V25	= 760,			/* datasheet typical, millivolts */
	Slopeq	= 25,			/* 2.5mV per degree, in tenths */
	/*
	 * VBAT does not reach the converter directly: an F405 or F407
	 * halves it first.  An F427 or F429 quarters it instead, and
	 * puts it on channel 18 shared with the temperature sensor, so
	 * this constant and the channel above it are both part-specific
	 * and not family-specific.  Measured here, and that is how the
	 * four this file had first was found: with VBAT tied to the
	 * 3.3V rail the pin read 1647mV, which is half and not a
	 * quarter, and the file was reporting a 6.6V battery on a board
	 * that has no such rail.
	 */
	Vbatdiv	= 2,

	Spins	= 100000,
};

typedef struct Chan1 Chan1;
struct Chan1
{
	char	*name;
	int	ch;
	int	pin;			/* on GPIOA, or -1 for internal */
};

static u32 *adc;
static u32 *adccommon;
static int adcok;

/*
 * The five, in the order the file prints them.  Order is not
 * arbitrary: an1 and an2 are what a click is on and come first.
 */
static Chan1 chans[] = {
	{ "an1",	2,	2 },	/* mikroBUS 1 AN, PA2 */
	{ "an2",	3,	3 },	/* mikroBUS 2 AN, PA3 */
	{ "temp",	16,	-1 },
	{ "vref",	17,	-1 },
	{ "vbat",	18,	-1 },
};

static void
analogpin(int pin)
{
	ulong v;

	v = *(volatile ulong*)(GPIOA+GPIO_MODER);
	v |= 3UL << (2*pin);			/* analogue: both bits */
	*(volatile ulong*)(GPIOA+GPIO_MODER) = v;
	v = *(volatile ulong*)(GPIOA+GPIO_PUPDR);
	v &= ~(3UL << (2*pin));			/* no pull: it is an input */
	*(volatile ulong*)(GPIOA+GPIO_PUPDR) = v;
}

/*
 * Sample time for one channel, three bits a channel, split across two
 * registers at ten.  480 cycles for every channel here: the
 * temperature sensor wants at least 10us and at 21MHz that is 210
 * cycles, and nothing on this board is fast enough to care about the
 * rest.
 */
static void
sampletime(int ch)
{
	int sh;

	if(ch < 10){
		sh = 3*ch;
		adc[Smpr2] |= 7UL << sh;
	} else {
		sh = 3*(ch-10);
		adc[Smpr1] |= 7UL << sh;
	}
}

/*
 * One conversion.  RM0090 13.3.1: select the channel as the first and
 * only one in the regular sequence, start, wait for EOC, read DR --
 * and reading DR is what clears EOC, so nothing else may read it
 * first.  Returns the count, or -1 if the conversion did not finish.
 */
static int
convert(int ch)
{
	int i;

	adc[Sqr1] = 0;				/* L = 0: one conversion */
	adc[Sqr3] = ch;
	adc[Sr] = 0;
	adc[Cr2] = Adon | Swstart;
	for(i = 0; i < Spins; i++)
		if(adc[Sr] & Eoc)
			return adc[Dr] & Full;
	return -1;
}

static int
millivolts(int raw)
{
	if(raw < 0)
		return -1;
	return (raw * Vrefmv) / Full;
}

/*
 * VBAT in millivolts, for whoever wants the one number rather than the
 * whole file.
 *
 * archfilesstm32f4.c serves it as #P/battery because that is the name
 * module/pycubedhw.m gives the mission's battery, and a mission should
 * not have to parse a five-line diagnostic file to find one figure.
 * The division is the part's own: RM0090 13.11 puts VBAT on channel 18
 * through a divide-by-two, so the count is half the rail.
 *
 * -1 if the converter did not finish or was never brought up, which is
 * a reading the caller has to be able to tell from a voltage.
 */
int
adcbattmv(void)
{
	int mv;

	if(!adcok)
		return -1;
	mv = millivolts(convert(18));
	if(mv < 0)
		return -1;
	return Vbatdiv * mv;
}

static s32
adcread(Chan*, void *a, s32 n, s64 offset)
{
	char *s, *e, *p;
	int i, raw, mv, t;
	s32 rv;

	if(!adcok)
		error("no adc");
	s = smalloc(READSTR);
	if(waserror()){
		free(s);
		nexterror();
	}
	e = s + READSTR;
	p = s;
	for(i = 0; i < nelem(chans); i++){
		raw = convert(chans[i].ch);
		mv = millivolts(raw);
		if(raw < 0){
			p = seprint(p, e, "%s - -\n", chans[i].name);
			continue;
		}
		p = seprint(p, e, "%s %d %d", chans[i].name, raw, mv);
		switch(chans[i].ch){
		case 16:
			/*
			 * Tenths of a degree, to keep the arithmetic in
			 * integers: (mv - V25) * 10 / 2.5 + 250.
			 */
			t = ((mv - V25) * 100) / Slopeq + 250;
			p = seprint(p, e, " %d.%d", t/10, t < 0? -t%10: t%10);
			break;
		case 18:
			p = seprint(p, e, " %d", Vbatdiv*mv);
			break;
		}
		p = seprint(p, e, "\n");
	}
	rv = readstr(offset, a, n, s);
	poperror();
	free(s);
	return rv;
}

void
adcstm32f4link(void)
{
	int i;

	*(volatile ulong*)RCC_AHB1ENR |= Ahb1Gpioa;
	*(volatile ulong*)RCC_APB2ENR |= Apb2Adc1;
	coherence();

	adc = (u32*)ADC1;
	adccommon = (u32*)ADCCOMMON;

	for(i = 0; i < nelem(chans); i++)
		if(chans[i].pin >= 0)
			analogpin(chans[i].pin);

	/*
	 * APB2 is 84MHz and the converter's maximum is 36, so it is
	 * divided by four.  TSVREFE and VBATE connect the temperature
	 * sensor, the internal reference and the backup battery's
	 * divider to their channels; without them those three read
	 * whatever is floating.
	 */
	adccommon[Ccr] = Adcpre4 | Tsvrefe | Vbate;
	adc[Cr1] = 0;				/* 12 bit, no scan */
	adc[Cr2] = 0;
	adc[Smpr1] = 0;
	adc[Smpr2] = 0;
	for(i = 0; i < nelem(chans); i++)
		sampletime(chans[i].ch);
	adc[Cr2] = Adon;
	coherence();
	/*
	 * tSTAB after ADON before the first conversion: three
	 * microseconds on this part.  Spun for rather than slept
	 * through, because links() runs before there is a process to
	 * sleep.
	 */
	for(i = 0; i < 1000; i++)
		coherence();

	adcok = 1;
	addarchfile("adc", 0444, adcread, nil);
}
