/*
 * STM32F303 registers, by the names the reference manual (RM0316) gives
 * them.  Only what this kernel touches is here.
 */

#define	RCC		0x40021000
#define	  RCC_CR	(RCC+0x00)
#define	    CrHsion	(1<<0)
#define	    CrHsirdy	(1<<1)
#define	    CrPllon	(1<<24)
#define	    CrPllrdy	(1<<25)
#define	  RCC_CFGR	(RCC+0x04)
#define	    CfgrSwPll	(2<<0)
#define	    CfgrSwsMask	(3<<2)
#define	    CfgrSwsPll	(2<<2)
#define	    CfgrPpre1Div2 (4<<8)	/* APB1 is 36MHz at most */
#define	    CfgrPllsrcHsi (0<<16)	/* HSI/2 */
#define	    CfgrPllmul16 (14<<18)	/* the field counts from two */
#define	  RCC_AHBENR	(RCC+0x14)
#define	    AhbGpioa	(1<<17)
#define	  RCC_APB1ENR	(RCC+0x1c)
#define	    Apb1Usart2	(1<<17)

#define	FLASHIF		0x40022000
#define	  FLASH_ACR	(FLASHIF+0x00)
#define	    AcrLatency2	(2<<0)		/* two wait states above 48MHz */
#define	    AcrPrftbe	(1<<4)

#define	GPIOA		0x48000000
#define	  GPIO_MODER	0x00
#define	  GPIO_OSPEEDR	0x08
#define	  GPIO_AFRL	0x20

/*
 * USART.  The F3's is the one with the separate BRR; a byte at a time in
 * and out, no fifo.
 */
enum {
	UartCr1		= 0x00,
	  UartUe	= 1<<0,		/* enable */
	  UartRe	= 1<<2,
	  UartTe	= 1<<3,
	  UartRxneie	= 1<<5,		/* receive interrupt enable */
	UartCr2		= 0x04,
	UartCr3		= 0x08,
	UartBrr		= 0x0c,
	UartIsr		= 0x1c,
	  UartOre	= 1<<3,		/* overrun */
	  UartRxne	= 1<<5,		/* read data register not empty */
	  UartTc	= 1<<6,
	  UartTxe	= 1<<7,		/* transmit data register empty */
	UartIcr		= 0x20,
	UartRdr		= 0x24,
	UartTdr		= 0x28,
};

/*
 * USART2 hangs off APB1, which the clock setup divides to half the core
 * clock.
 */
#define	UARTCLK		(CPUHZ/2)
