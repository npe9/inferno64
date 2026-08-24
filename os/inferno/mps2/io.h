/*
 * The CMSDK APB UART, which is what the MPS2 FPGA images carry.
 * Registers are 32 bit and a word apart.
 */
enum {
	UartData	= 0x00,
	UartState	= 0x04,
	  UartTxfull	= 1<<0,
	  UartRxfull	= 1<<1,
	  UartTxover	= 1<<2,
	  UartRxover	= 1<<3,
	UartCtrl	= 0x08,
	  UartTxen	= 1<<0,
	  UartRxen	= 1<<1,
	  UartTxirqen	= 1<<2,
	  UartRxirqen	= 1<<3,
	UartIntstatus	= 0x0c,		/* write one to clear */
	  UartTxirq	= 1<<0,
	  UartRxirq	= 1<<1,
	UartBauddiv	= 0x10,
};
