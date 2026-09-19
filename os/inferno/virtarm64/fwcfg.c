/*
 * QEMU fw_cfg, the DMA transport and the file directory.
 *
 * This lived inside screenarm.c, which is the ramfb display driver,
 * because the display was the first thing that needed it.  Then
 * bootargs.c started reading the boot options through it -- and
 * virtarm64cloud, which is a t2a with no framebuffer at all, leaves
 * screenarm out.  That board stopped linking: "fwcfgbootargs:
 * undefined: fwcfgfile".  A firmware interface is not a display driver,
 * so it is its own file and both configurations name it.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"

enum {
	FwCfgBase	= ((uintptr)0x9020000),	/* arm64 virt fw_cfg */
	FwCfgSel	= FwCfgBase + 8,
	FwCfgDmaReg	= FwCfgBase + 16,

	FwCfgFileDir	= 0x19,
	FwCfgDmaRead	= 1<<1,
	FwCfgDmaSelect	= 1<<3,
};

typedef struct FwDmaDesc FwDmaDesc;
struct FwDmaDesc
{
	u32int	control;
	u32int	length;
	u64int	address;
};

static u32int
be32(u32int v)
{
	return (v>>24) | ((v>>8)&0xff00) | ((v<<8)&0xff0000) | (v<<24);
}

static u64int
be64(u64int v)
{
	return ((u64int)be32((u32int)v)<<32) | (u64int)be32((u32int)(v>>32));
}

/*
 * A static descriptor, not a malloc'd one.  bootargsinit() reads the
 * boot options through here, and it runs before the allocator exists --
 * it has to, because the loader leaves its block in memory the kernel
 * is about to allocate over.  malloc() returned nil there and this
 * returned -1, so the options silently did not arrive and every
 * *parallelvm, *soak and *secsched on a -kernel boot line was ignored.
 *
 * Safe because fw_cfg is read at boot, by one processor: the options
 * here, and the framebuffer in screenarm.c before any other processor
 * is started.
 */
int
fwcfgdma(u32int control, void *buf, u32int len)
{
	static FwDmaDesc dmabuf;
	FwDmaDesc *dma;
	u64int dmap;

	dma = &dmabuf;
	memset(dma, 0, sizeof(*dma));
	dma->control = be32(control);
	dma->length = be32(len);
	dma->address = be64((u64int)(uintptr)buf);
	coherence();
	dmap = (u64int)(uintptr)dma;
	*(volatile u32int*)FwCfgDmaReg = be32((u32int)(dmap>>32));
	*(volatile u32int*)(FwCfgDmaReg+4) = be32((u32int)dmap);
	while(be32(dma->control) & ~(u32int)1)
		;
	if(be32(dma->control) & 1)
		return -1;
	return 0;
}

/*
 * Find an item in the fw_cfg file directory by name.  Boot options
 * arrive as "opt/bootargs" from QEMU's -fw_cfg, because this board is
 * loaded as a bare ELF and FW_CFG_CMDLINE is empty for that (measured:
 * fw_cfg says 0 bytes).  Returns the selector, and the item's size
 * through *size.
 *
 * Directory entry: be32 size, be16 select, be16 reserved, name[56].
 */
int
fwcfgfile(char *name, u32int *size)
{
	u32int count, i;
	uchar ent[64];
	u16int sel;
	int n;

	n = strlen(name);
	if(fwcfgdma(((u32int)FwCfgFileDir<<16) | FwCfgDmaSelect | FwCfgDmaRead,
	    &count, 4) < 0)
		return -1;
	count = be32(count);
	if(count > 512)
		count = 512;
	for(i = 0; i < count; i++){
		if(fwcfgdma(FwCfgDmaRead, ent, 64) < 0)
			return -1;
		sel = ((u16int)ent[4]<<8) | ent[5];
		if(strncmp((char*)(ent+8), name, n) == 0 && ent[8+n] == 0){
			if(size != nil)
				*size = ((u32int)ent[0]<<24) | ((u32int)ent[1]<<16)
					| ((u32int)ent[2]<<8) | ent[3];
			return (int)sel;
		}
	}
	return -1;
}
