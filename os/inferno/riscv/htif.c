/*
 * Spike HTIF console via ELF symbols tohost/fromhost (QEMU -M spike).
 *
 * QEMU maps HTIF over [min(tohost,fromhost), max+8).  The two cells
 * MUST be adjacent or ordinary data in the gap becomes "Invalid htif".
 * KenC may separate two BSS symbols, so we allocate one 16-byte cell
 * (tohost) in board l.s and treat fromhost as tohost+8.
 *
 * QEMU leaves a PUTC acknowledgement in fromhost (0x100|char).  That
 * must be drained — otherwise clockpoll's getc treats it as RX and
 * console echo floods newlines.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	HtifDevConsole	= 1,
	HtifCmdPutchar	= 1,
	HtifCmdGetchar	= 0,
};

extern volatile uvlong	tohost;	/* 16 bytes: [0]=tohost [1]=fromhost */

#define	fromhost	(*(volatile uvlong*)((uintptr)&tohost + 8))

static void
htif_send(uvlong device, uvlong cmd, uvlong payload)
{
	uvlong v;

	v = (device << 56) | (cmd << 48) | (payload & (((uvlong)1<<48)-1));
	while(tohost != 0)
		;
	tohost = v;
}

static int
htif_drain_fromhost(void)
{
	uvlong v;
	int i;

	for(i = 0; i < 1000000; i++){
		v = fromhost;
		if(v != 0){
			fromhost = 0;
			return (int)(v & 0xFF);
		}
	}
	return -1;
}

void
htifputc(int c)
{
	int s;

	s = splhi();
	htif_send(HtifDevConsole, HtifCmdPutchar, c & 0xFF);
	htif_drain_fromhost();	/* discard PUTC ack */
	splx(s);
}

int
htifgetc(void)
{
	uvlong v;
	int s;

	/*
	 * Non-blocking: clockpoll calls this every tick.  GETC does not
	 * set fromhost until a key arrives (htif_recv); absent input,
	 * return -1 immediately after the probe.
	 */
	s = splhi();
	if(fromhost != 0){
		/* leftover ack — should not happen after htifputc drain */
		fromhost = 0;
	}
	htif_send(HtifDevConsole, HtifCmdGetchar, 0);
	v = fromhost;
	if(v != 0){
		fromhost = 0;
		splx(s);
		return (int)(v & 0xFF);
	}
	splx(s);
	return -1;
}

void
htifputs(char *s, int n)
{
	if(n < 0){
		while(*s){
			if(*s == '\n')
				htifputc('\r');
			htifputc(*s++);
		}
		return;
	}
	while(--n >= 0){
		if(*s == '\n')
			htifputc('\r');
		htifputc(*s++);
	}
}
