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
#define	    CfgrSwsHsi	(0<<2)
#define	    CfgrSwsPll	(2<<2)
#define	    CfgrHpreDiv1 (0<<4)
#define	    CfgrPpre1Div1 (0<<10)
#define	    CfgrPpre2Div1 (0<<13)
#define	    CfgrPpre1Div4 (5<<10)	/* APB1 is 42MHz at most */
#define	    CfgrPpre2Div2 (4<<13)	/* APB2 is 84MHz at most */
#define	  RCC_AHB1ENR	(RCC+0x30)
#define	    Ahb1Gpioa	(1<<0)
#define	    Ahb1Gpiob	(1<<1)
#define	    Ahb1Gpioc	(1<<2)
#define	    Ahb1Gpiod	(1<<3)
#define	    Ahb1Gpioe	(1<<4)
#define	  RCC_APB1ENR	(RCC+0x40)
#define	    Apb1Usart2	(1<<17)
#define	    Apb1Usart3	(1<<18)
#define	    Apb1Uart4	(1<<19)
#define	  RCC_APB2ENR	(RCC+0x44)
#define	    Apb2Usart1	(1<<4)

#define	FLASHIF		0x40023c00
#define	  FLASH_ACR	(FLASHIF+0x00)
#define	    AcrLatency5	(5<<0)		/* five wait states at 168MHz, 3.3V */
#define	    AcrPrften	(1<<8)
#define	    AcrIcen	(1<<9)
#define	    AcrDcen	(1<<10)

/*
 * The GPIO blocks are a kilobyte apart, and each is the same register
 * file: MODER and OSPEEDR two bits a pin over all sixteen, and the
 * alternate function four bits a pin, in AFRL for pins 0 to 7 and AFRH
 * for 8 to 15, indexed within the register.
 */
#define	GPIOA		0x40020000
#define	GPIOB		0x40020400
#define	GPIOC		0x40020800
#define	GPIOD		0x40020c00
#define	GPIOE		0x40021000
#define	  GPIO_MODER	0x00
#define	  GPIO_OSPEEDR	0x08
#define	  GPIO_PUPDR	0x0c
#define	  GPIO_IDR	0x10
#define	  GPIO_ODR	0x14
#define	  GPIO_AFRL	0x20		/* pins 0 to 7 */
#define	  GPIO_AFRH	0x24		/* pins 8 to 15 */

/*
 * The console: which USART, on which pins.  mem.h defines exactly one
 * of the CONSUSART names below and says what each is and why this
 * board's is what it is.  Everything the driver and archreset() need
 * follows: the register block and its NVIC number, the port and the
 * two pins and which AFR register they are in, the AHB1 gate for the
 * port, and -- through UARTONAPB2 below -- the APB gate for the USART
 * and the frequency its baud divisor is computed from.  Every pin any
 * of these can use is alternate function 7.
 *
 * #ifdef and not #if: kencc's preprocessor has no #if, which is why
 * NERR and the rest of the portable sizes are spelt the way they are
 * too.  Define none of them and the build stops at UART0 undefined.
 */
#ifdef CONSUSART1			/* USART1, PA9 and PA10 */
#define	UART0		0x40011000
#define	UART0IRQ	37
#define	UARTPORT	GPIOA
#define	UARTGPIOEN	Ahb1Gpioa
#define	UARTTX		9
#define	UARTRX		10
#define	UARTAFR		GPIO_AFRH
#define	UARTONAPB2
#define	UARTAPBBIT	Apb2Usart1
#endif

#ifdef CONSUSART2			/* USART2, PD5 and PD6 */
#define	UART0		0x40004400
#define	UART0IRQ	38
#define	UARTPORT	GPIOD
#define	UARTGPIOEN	Ahb1Gpiod
#define	UARTTX		5
#define	UARTRX		6
#define	UARTAFR		GPIO_AFRL
#define	UARTAPBBIT	Apb1Usart2
#endif

#ifdef CONSUSART2A			/* USART2, PA2 and PA3 */
#define	UART0		0x40004400
#define	UART0IRQ	38
#define	UARTPORT	GPIOA
#define	UARTGPIOEN	Ahb1Gpioa
#define	UARTTX		2
#define	UARTRX		3
#define	UARTAFR		GPIO_AFRL
#define	UARTAPBBIT	Apb1Usart2
#endif

#ifdef CONSUSART3			/* USART3, PD8 and PD9 */
#define	UART0		0x40004800
#define	UART0IRQ	39
#define	UARTPORT	GPIOD
#define	UARTGPIOEN	Ahb1Gpiod
#define	UARTTX		8
#define	UARTRX		9
#define	UARTAFR		GPIO_AFRH
#define	UARTAPBBIT	Apb1Usart3
#endif

#ifdef CONSUSART3C			/* USART3, PC10 and PC11 */
#define	UART0		0x40004800
#define	UART0IRQ	39
#define	UARTPORT	GPIOC
#define	UARTGPIOEN	Ahb1Gpioc
#define	UARTTX		10
#define	UARTRX		11
#define	UARTAFR		GPIO_AFRH
#define	UARTAPBBIT	Apb1Usart3
#endif

/*
 * USART1 is on APB2 and USART2 and USART3 on APB1: a different clock
 * gate, and a different frequency behind the baud divisor.
 */
#ifdef UARTONAPB2
#define	UARTAPBENR	RCC_APB2ENR
#define	UARTHZ		apb2hz
#else
#define	UARTAPBENR	RCC_APB1ENR
#define	UARTHZ		apb1hz
#endif

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
