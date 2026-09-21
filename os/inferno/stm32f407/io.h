/*
 * STM32F407 registers, by the names the reference manual (RM0090) gives
 * them.  Only what this kernel touches is here.
 *
 * These are not the F303's.  RCC, FLASH and the GPIO block are all at
 * different addresses, the PLL is configured through a register the F3
 * does not have, and the USART is the older one with SR and DR where
 * the F3 has ISR, RDR and TDR.  os/inferno/nucleof303 shares this
 * kernel's core and nothing in this file.
 */

#define	RCC		0x40023800
#define	  RCC_CR	(RCC+0x00)
#define	    CrHsion	(1<<0)
#define	    CrHsirdy	(1<<1)
#define	    CrHseon	(1<<16)
#define	    CrHserdy	(1<<17)
#define	    CrPllon	(1<<24)
#define	    CrPllrdy	(1<<25)
#define	  RCC_PLLCFGR	(RCC+0x04)
#define	    PllsrcHsi	(0<<22)
#define	  RCC_CFGR	(RCC+0x08)
#define	    CfgrSwHsi	(0<<0)
#define	    CfgrSwPll	(2<<0)
#define	    CfgrSwsMask	(3<<2)
#define	    CfgrSwsPll	(2<<2)
#define	    CfgrHpreDiv1 (0<<4)
#define	    CfgrPpre1Div1 (0<<10)
#define	    CfgrPpre2Div1 (0<<13)
#define	    CfgrPpre1Div4 (5<<10)	/* APB1 is 42MHz at most */
#define	    CfgrPpre2Div2 (4<<13)	/* APB2 is 84MHz at most */
#define	  RCC_AHB1ENR	(RCC+0x30)
#define	    Ahb1Gpioa	(1<<0)
#define	  RCC_APB1ENR	(RCC+0x40)
#define	    Apb1Usart2	(1<<17)
#define	  RCC_APB2ENR	(RCC+0x44)
#define	    Apb2Usart1	(1<<4)

#define	FLASHIF		0x40023c00
#define	  FLASH_ACR	(FLASHIF+0x00)
#define	    AcrLatency5	(5<<0)		/* five wait states at 168MHz, 3.3V */
#define	    AcrPrften	(1<<8)
#define	    AcrIcen	(1<<9)
#define	    AcrDcen	(1<<10)

#define	GPIOA		0x40020000
#define	  GPIO_MODER	0x00
#define	  GPIO_OSPEEDR	0x08
#define	  GPIO_AFRL	0x20		/* pins 0 to 7 */
#define	  GPIO_AFRH	0x24		/* pins 8 to 15 */

/*
 * USART.  The F4's is the one with SR and DR; a byte at a time in and
 * out, no fifo.
 */
enum {
	UartSr		= 0x00,
	  UartOre	= 1<<3,		/* overrun */
	  UartRxne	= 1<<5,		/* read data register not empty */
	  UartTc	= 1<<6,
	  UartTxe	= 1<<7,		/* transmit data register empty */
	UartDr		= 0x04,
	UartBrr		= 0x08,
	UartCr1		= 0x0c,
	  UartRe	= 1<<2,
	  UartTe	= 1<<3,
	  UartRxneie	= 1<<5,		/* receive interrupt enable */
	  UartUe	= 1<<13,	/* enable; bit 0 on the F3 */
	UartCr2		= 0x10,
	UartCr3		= 0x14,
};

/*
 * USART1 hangs off APB2 and USART2 off APB1.  What either is depends
 * on which clock the boot settled on, so uartboardinit() asks rather
 * than assuming; see archstm32f407.c.
 */
extern ulong apb1hz;
extern ulong apb2hz;
