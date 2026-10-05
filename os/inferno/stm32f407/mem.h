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
 *			two banks, so eight is four more than it can
 *			ever need.
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
/*
 * One line of console input, os/inferno/port/devcons.c; 1024 is the
 * portable default.  256 is four times the longest command anything
 * here can usefully be given.
 */
#define	NCONSLINE	256
#define	NHOLE		8
#define	NMNTTAG		1024

/*
 * I2C: how many controllers and how many addresses #J will remember.
 * The portable default is 16 and 1024, which is 4160 bytes of bss --
 * a fortieth of this board's RAM for a bus that has two controllers
 * and, on a clicker 2, at most one part in each socket.
 */
#define	NI2CBUS		2
#define	NI2CDEV		8

#define	MAXMACH		1
#define	HZ		100
/*
 * The kernel stack, one per proc, xalloc'd at boot; see
 * KSTACKPREALLOC below.
 *
 * 4096 is inherited and 2476 is the deepest any proc here has actually
 * gone -- measured, not guessed, by KSTACKWATCH below: newproc() fills
 * a new stack with 0xbe and kstackused() reads back how far the
 * pattern has been eaten.  That was over a boot, the floating point
 * register tests, ls(1) of /dev, grep(1), cat(1) and ps(1).
 *
 * It stays at 4096 all the same.  3072 was tried, and the workload
 * that would justify it -- a shell pipeline -- cannot run on this
 * board for an unrelated reason, so the deep paths are exactly the
 * ones unmeasured.  A stack overflow on an untested path is a poor
 * trade for 1024 bytes a proc.  Worth revisiting when a pipeline runs
 * and can be watched.
 */
#define	KSTACK		(4*1024)
/*
 * Take all conf.nproc stacks from xalloc at boot rather than letting
 * newproc() malloc each one the first time its Proc is used.  Nothing
 * frees a kernel stack -- a dead proc goes back on the free list with
 * its stack attached -- so the total is the same either way; what
 * differs is that a late 4096-byte request out of a fragmented main
 * pool fails, and it fails at a fork, which is where the shell is
 * when it opens a file with ">".  See os/inferno/port/proc.c.
 */
#define	KSTACKPREALLOC	1
#define	KSTACKWATCH	1	/* measure it; see os/inferno/port/proc.c */
/*
 * The number of processes is NOT here any more.  It is nprocwanted in
 * this board's config file, beside main_pool_pcnt, because one board
 * has two images that want different numbers and a constant in a header
 * cannot say that.  The measurements are in the config, where the value
 * is.
 */
/*
 * THE CALIBRATION STORE, AND WHY IT IS A TAIL AND NOT A SECTOR.
 *
 * doc/radio-plan.ms item 8's second stage wants a board to be able to
 * write down what it has just measured, and sketched it as a spare 128K
 * flash sector.  This part has no spare sector.  Measured against
 * RM0090 table 5 with the image this tree builds:
 *
 *	sectors 0-9     0x08000000..0x080bffff   all image
 *	sector 10       0x080c0000..0x080dffff   image ends inside it
 *	sector 11       0x080e0000..0x080fffff   the HID bootloader
 *
 * The image is 889112 bytes and ends at 0x080d9118, so sector 10 is
 * half used and sector 11 is the only way back into the board.  What is
 * spare is the TAIL of sector 10 -- and it has never been written, so
 * it is still erased.
 *
 * That turns out to suit the job better than a sector would.  Flash
 * programming turns ones into zeroes, so appending to erased flash needs
 * no erase: no sector-erase driver, no wear levelling, and no window
 * where a power cut leaves the store erased instead of old.  The only
 * thing that erases this region is a reflash, which rewrites /lib/radio
 * anyway.  So the store is an APPEND-ONLY LOG that is never erased, and
 * a reader takes the last entry for a uid.
 *
 * The base is fixed rather than taken from a linker symbol, because a
 * symbol would move with every build and a record written against one
 * address would be unreadable by the next image.  The build is what
 * stops the image growing into it: the mkfile gives bin2ihex this
 * address as its ceiling, so an image that would overlap the store fails
 * to convert rather than overwriting it.  Both numbers are here and in
 * the mkfile and each says to check the other.
 */
/*
 * 8K and not 16, which is a measurement replacing a guess.
 *
 * It was 16K because 16K was spare.  What the store actually holds is
 * attrdb lines -- a uid, a ppb, an rssioffset and a threshold -- and
 * calinfo reported "used 95" after a board wrote its first entry.  At
 * a hundred bytes an entry, 8K is eighty of them, and a reflash erases
 * the store in any case because the bootloader's last 32K write block
 * covers it.  Eighty measurements between reflashes is not the
 * constraint on this board.
 *
 * What the rest buys is image: the ceiling bin2ihex is given is this
 * base, and a shell image carrying the PyCubed mission's modules in its
 * root came to 901320 bytes against the original 901120 and would not
 * convert.  So the store gives up what it has never used, to the thing
 * that is actually short.
 *
 * 4K IS THE LAST HALVING, and the fact that this knob has been turned
 * twice in one session is the real finding.  Forty entries is still
 * more measurements than a board takes between reflashes, but the thing
 * that is actually wrong is that EVERY image carries EVERY root file:
 * the shell image carries the mission's three modules and cannot run
 * them, the mission image carries the shell and cannot run it.  The XIP
 * list and the process count are per init already, in image-<init>
 * beside the config.  The root is not, because mkroot reads the conf's
 * root section and the conf format has no way to say "this file only
 * for that init" -- and that, not this constant, is what the next thing
 * added to the root should fix.
 */
#define	CALBASE		0x080df000
#define	CALSIZE		(4*1024)

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

/*
 * And 4K of backup SRAM, which is the "+4" in the datasheet's "192+4
 * KB".  It is ordinary memory to the core once RCC_AHB1ENR's BKPSRAMEN
 * is set; what makes it "backup" is that it can be kept alive from VBAT
 * across a power cycle, which needs PWR_CR's DBP and PWR_CSR's BRE and
 * which nothing here asks for.  A third bank of one page, on a board
 * where a page is worth going after.
 */
#define	BKPSRAM		0x40024000
#define	BKPSRAMSIZE	(4*1024)

#define	KZERO		FLASHBASE
#define	KTZERO		FLASHBASE	/* link address: the vector table */
#define	KDZERO		SRAM
#define	TOPOFMEM	(SRAM+SRAMSIZE)
#define	USTKTOP		TOPOFMEM
#define	MACHADDR	0

/*
 * Which USART is the console, and on which pins: define exactly one of
 * these, and io.h turns it into a register block, an NVIC number, a
 * port, two pins and two clock gates.
 *
 *	CONSUSART1	USART1, PA9 and PA10.  The pins the part's own
 *			ROM bootloader speaks, and the usual pair on a
 *			bare F407.
 *	CONSUSART2	USART2, PD5 and PD6.  mikroBUS 1 on a MikroE
 *			clicker 2 for STM32.
 *	CONSUSART3	USART3, PD8 and PD9.  mikroBUS 2 on the same.
 *	CONSUSART3C	USART3, PC10 and PC11.  The ROM bootloader's
 *			other pair; on a clicker 2 they are mikroBUS 1's
 *			SCK and MISO.
 *	CONSUSART2A	USART2, PA2 and PA3.  The ST-Link virtual port
 *			on a NUCLEO-F407.
 *
 * CONSUSART2, for a USB UART click in mikroBUS 1 and the radio in
 * mikroBUS 2.  The manual is right about this board after all: the
 * hours spent doubting it were a click seated the wrong way round,
 * which lines its pins up against the opposite header and puts its
 * receive and transmit on whatever happens to be there.  Every
 * measurement taken while it was reversed agreed with every other and
 * all of them were about a click that was not connected to what it
 * appeared to be connected to.  otherusarts() below says which socket
 * is speaking, so the choice here is checked and not assumed.
 *
 * Under qemu's netduinoplus2 USART1 is serial_hd(0), USART2 is
 * serial_hd(1) and USART3 is serial_hd(2), so CONSUSART2 wants
 *	-serial null -serial mon:stdio
 * and the USART3 ones want another -serial null before that.
 */
#define	CONSUSART2

#define	UARTBAUD	115200

/* EXTI lines 10 to 15 share one NVIC interrupt, RM0090 table 62 */
#define	EXTI15_10IRQ	40
