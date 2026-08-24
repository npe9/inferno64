/*
 * i.MX RT1062 registers, by the names chapters 14 (CCM), 12 (IOMUXC)
 * and 49 (LPUART) of the reference manual give them.  Only what this
 * kernel touches is here.
 */

/* Clock Controller Module */
#define	CCM		0x400fc000
#define	  CCM_CCGR0	(CCM+0x68)
#define	  CCM_CCGR1	(CCM+0x6c)
#define	  CCM_CCGR2	(CCM+0x70)
#define	  CCM_CCGR3	(CCM+0x74)
#define	  CCM_CCGR4	(CCM+0x78)
#define	  CCM_CCGR5	(CCM+0x7c)
#define	  CCM_CCGR6	(CCM+0x80)
#define	  CCM_CBCDR	(CCM+0x14)
#define	  CCM_CBCMR	(CCM+0x18)
#define	  CCM_CSCMR1	(CCM+0x1c)
#define	  CCM_CSCDR1	(CCM+0x24)
#define	  CCM_CACRR	(CCM+0x10)
#define	  CCM_CDHIPR	(CCM+0x48)

/* the analogue half of it, where the PLLs are */
#define	CCM_ANALOG	0x400d8000
#define	  PLL_ARM	(CCM_ANALOG+0x00)
#define	    PllArmEnable	(1<<13)
#define	    PllArmPowerdown	(1<<12)
#define	    PllArmLock		(1<<31)
#define	    PllArmDivSelect	0x7f

/* pin multiplexing */
#define	IOMUXC		0x401f8000
#define	  IOMUXC_MUX_AD_B0_02	(IOMUXC+0x0cc)	/* pin 1, LPUART6_TX on ALT2 */
#define	  IOMUXC_MUX_AD_B0_03	(IOMUXC+0x0d0)	/* pin 0, LPUART6_RX on ALT2 */
#define	  IOMUXC_PAD_AD_B0_02	(IOMUXC+0x2bc)
#define	  IOMUXC_PAD_AD_B0_03	(IOMUXC+0x2c0)

/* the general purpose registers, where the FlexRAM is divided up */
#define	IOMUXC_GPR	0x400ac000
#define	  IOMUXC_GPR14	(IOMUXC_GPR+0x38)
#define	  IOMUXC_GPR16	(IOMUXC_GPR+0x40)
#define	  IOMUXC_GPR17	(IOMUXC_GPR+0x44)
#define	    Gpr16Itcmen		(1<<0)
#define	    Gpr16Dtcmen		(1<<1)
#define	    Gpr16Banksel	(1<<2)	/* take the split from GPR17, not the fuses */

/* watchdogs, which are off at reset but are turned off here anyway */
#define	WDOG1		0x400b8000
#define	WDOG2		0x400d0000
#define	RTWDOG		0x400bc000

/*
 * LPUART.  Registers are 32 bit; the ones this driver uses are the
 * baud rate, the status, the control and the data.
 */
enum {
	UartVerid	= 0x00,
	UartParam	= 0x04,
	UartGlobal	= 0x08,
	  UartRst	= 1<<1,		/* software reset */
	UartPincfg	= 0x0c,
	UartBaud	= 0x10,
	  UartOsrshift	= 24,
	  UartSbrmask	= 0x1fff,
	  UartM10	= 1<<29,
	  UartBothedge	= 1<<17,
	UartStat	= 0x14,
	  UartTdre	= 1<<23,	/* transmit data register empty */
	  UartTc	= 1<<22,	/* transmission complete */
	  UartRdrf	= 1<<21,	/* receive data register full */
	  UartIdle	= 1<<20,
	  UartOr	= 1<<19,	/* receiver overrun */
	UartCtrl	= 0x18,
	  UartTie	= 1<<23,	/* transmit interrupt enable */
	  UartRie	= 1<<21,	/* receive interrupt enable */
	  UartTe	= 1<<19,	/* transmitter enable */
	  UartRe	= 1<<18,	/* receiver enable */
	UartData	= 0x1c,
	UartFifo	= 0x28,
	  UartRxflush	= 1<<14,
	  UartTxflush	= 1<<15,
	UartWater	= 0x2c,
};

/*
 * The clock that reaches an LPUART.  CSCDR1 selects between PLL3 divided
 * by six and the 24MHz crystal, and divides what it picks; at reset it
 * is the 80MHz one undivided, which is what this kernel leaves it as.
 */
#define	UARTCLK		80000000
