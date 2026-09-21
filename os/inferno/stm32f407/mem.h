/*
 * An STM32F407: a Cortex-M4 with the single precision floating point
 * extension, a megabyte of flash and 192K of RAM in two pieces.
 *
 * The RAM is why this board exists beside os/inferno/nucleof303.  That
 * one is an F303 with 80K, and its NOTE records that it cannot run
 * Limbo: the kernel's own pool floor is about 97000 bytes before
 * anything is loaded.  128K of SRAM clears it with room, and the 64K
 * of core coupled memory is a second bank on top.
 *
 * No MMU, so every address here is both physical and virtual.
 */
#define	BI2BY		8
#define	BI2WD		32
#define	BY2WD		4
#define	BY2V		8
#define	BY2PG		4096
#define	WD2PG		(BY2PG/BY2WD)
#define	PGSHIFT		12
#define	ROUND(s, sz)	(((s)+(sz-1))&~(sz-1))
#define	PGROUND(s)	ROUND(s, BY2PG)

#define	MIN(a, b)	((a) < (b)? (a): (b))
#define	MAX(a, b)	((a) > (b)? (a): (b))

/*
 * The console log.  16K is the default in os/inferno/port/portdat.h and
 * is a lot of a part with a couple of hundred kilobytes of SRAM; 512
 * bytes still holds the last few lines of the boot.
 *
 * The exact figure matters here in a way it would not elsewhere.
 * conf.base0 is PGROUND(end), so what the kernel's data and bss cost
 * the pools is rounded up to a whole 4096-byte page: with KMESGSIZE at
 * 1024 the kernel ended 24 bytes into a ninth page and the board had
 * 159744 bytes, and with it at 512 the ninth page is given back.
 */
#define	KMESGSIZE	512

/*
 * waserror() nesting depth, and so the size of Proc.errlab at 8 bytes
 * an entry, times NPROC.  64 is the portable default (os/inferno/port/
 * portdat.h); measured on mps2 over a shell, failing opens, background
 * jobs, fptest and cvtchk, the deepest nesting reached was 8.  24 is
 * three times that, and saves 320 bytes in every Proc.
 */
#define	NERR		24

/*
 * Three portable defaults that are sized for a machine with megabytes
 * and are a measurable fraction of this board.  Each has an #ifndef in
 * the portable file that defines it; what is saved here was measured
 * from the linker's symbol table, against 147456 bytes of usable RAM.
 *
 *	STAGESIZE	os/inferno/port/portdat.h; 2048 each way in
 *			every Uart, and the one Uart on this board was
 *			4416 bytes.  256 each way is what the console
 *			below has been run with.
 *	NHOLE		os/inferno/port/xalloc.c; 128 free-memory runs
 *			at 20 bytes each.  This board's conf.mem has
 *			two banks.
 *	NMNTTAG		os/inferno/port/devmnt.c; a bit for each of the
 *			65536 tags 9P can express, 8192 bytes of bss.
 *			This board mounts nothing over a network and has
 *			six processes.
 *
 * Together they are 13440 bytes, nine per cent of the RAM, and the
 * difference between a shell that can load a second command and one
 * that cannot.
 */
#define	STAGESIZE	256
#define	NHOLE		16
#define	NMNTTAG		1024

#define	MAXMACH		1
#define	HZ		100
#define	KSTACK		(4*1024)
#define	NPROC		5
#define	CONFNAME	"stm32f407"

/*
 * What SysTick is told it is counting.  The part comes out of reset on
 * a 16MHz internal oscillator; archreset() tries the PLL for 168MHz
 * and falls back, and sets m->cpuhz to whichever it got, so this is
 * the reset value and not a promise.
 */
#define	CPUHZ		16000000

#define	KSTKSIZE	(4*1024)
#define	MACHSIZE	1024

#define	NIRQ		96
#define	IRQVECTORS	V64; V16; V16

#define	FLASHBASE	0x08000000
#define	FLASHSIZE	(1024*1024)
#define	SRAM		0x20000000
#define	SRAMSIZE	(128*1024)
#define	CCMRAM		0x10000000
/*
 * The F4's core coupled memory is reachable by the core's data bus and
 * by nothing else: no DMA, and no instruction fetch.  Data and bss can
 * live there; code cannot.
 */
#define	CCMRAMSIZE	(64*1024)

#define	KZERO		FLASHBASE
#define	KTZERO		FLASHBASE	/* link address: the vector table */
#define	KDZERO		SRAM
#define	TOPOFMEM	(SRAM+SRAMSIZE)
#define	USTKTOP		TOPOFMEM
#define	MACHADDR	0

/*
 * Which USART is the console.  The register block, the NVIC number,
 * the pins and the APB the baud divisor is computed from all follow
 * from this one definition; see uartstm32f4.c.  It is #define and not
 * a number because os/inferno/armv7m/l.s includes this file and 5a's
 * preprocessor knows #ifdef and not #if.
 *
 * USART1, on PA9 and PA10, because that is the pair the part's own ROM
 * bootloader speaks.  A board with no ST-Link is programmed by holding
 * BOOT0 high and talking to that bootloader over a serial adapter
 * (stm32flash(1) does it), and with the console on the same pins the
 * one pair of wires both writes the kernel and carries its shell.
 * USART1 is also serial_hd(0) under qemu's netduinoplus2, which is
 * what plain -nographic connects.
 *
 * USART2, on PA2 and PA3, is the ST-Link virtual port on a
 * NUCLEO-F407.  A board wired that way comments the line below out and
 * needs a probe, or a wire moved to PA9 and PA10 to flash and back
 * again to watch.
 */
#define	CONSUSART1

#ifdef CONSUSART1
#define	UART0		0x40011000	/* USART1 */
#define	UART0IRQ	37		/* USART1's NVIC interrupt number */
#else
#define	UART0		0x40004400	/* USART2 */
#define	UART0IRQ	38		/* USART2's NVIC interrupt number */
#endif
#define	UARTBAUD	115200
