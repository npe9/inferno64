/* QEMU -M spike: CLINT only (no PLIC) */
enum {
	ClintMtimecmp	= 0x4000,
	ClintMtime	= 0xbff8,
};

#define BUSUNKNOWN	(-1)
