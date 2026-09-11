#include <u.h>
#include "fns.h"
#include "efi.h"

UINTN MK;
/*
 * The firmware's memory map, kept after memconf() has taken MK out of
 * it so that memtopat() below can walk it.
 *
 * static, not automatic, and for two reasons.  A 96K map buffer on the
 * firmware's own stack is a lot to ask of it; and 7c cannot pass the
 * address of a stack local as an argument to a variadic function on
 * arm64 -- it emits a DWORD of a stack address-constant and 7l refuses
 * it as "illegal combination DWORD NONE NONE LACON".  The addresses of
 * statics are $sym(SB) and assemble.
 */
static UINTN mapsize, entsize;
static uchar mapbuf[96*1024];

/*
 * What memtopat() counts as the kernel's, which is not the same
 * question memconf()'s table answers.
 *
 * memconf() is describing memory to a pc kernel that will read the map
 * while boot services are still meaningful, so it calls boot-services
 * code and data reserved.  memtopat() is answering for a kernel that
 * runs after ExitBootServices(), and at that point the firmware's
 * boot-services memory is the guest's -- every OS reclaims it.  Calling
 * it reserved here does not make the kernel safer, it makes the run
 * stop at the first thing edk2 happened to allocate in the middle of
 * DRAM: measured, that was 0x44000000 on a machine with memory to
 * 0x80000000, and 63MB free where there had been 532MB.
 *
 * Runtime services, ACPI reclaim and ACPI NVS stay barriers.  Runtime
 * and NVS because the firmware keeps them across the call; reclaim
 * because the tables this board reads are in it, and the kernel reads
 * them after the allocator is live.
 */
static uchar mine[EfiMaxMemoryType] = {
	[EfiLoaderCode]			1,
	[EfiLoaderData]			1,
	[EfiBootServicesCode]		1,
	[EfiBootServicesData]		1,
	[EfiConventionalMemory]		1,
};
static int havemap;

EFI_HANDLE IH;
EFI_SYSTEM_TABLE *ST;

void* (*open)(char *name);
int (*read)(void *f, void *data, int len);
void (*close)(void *f);
void (*stop)(void);

/*
 * on ia32 and amd64, we use IMAGE_FILE_RELOCS_STRIPPED which
 * disables relocations, so this is a no-op.
 *
 * on arm64, the EFI loader can move our code, so we need to
 * update some of our stored addresses (such as callbacks)
 * which assume we are loaded at our requested base address.
 */
extern void *rebase(void *addr);

void
putc(int c)
{
	CHAR16 w[2];

	w[0] = c;
	w[1] = 0;
	eficall(ST->ConOut->OutputString, ST->ConOut, w);
}

int
getc(void)
{
	EFI_INPUT_KEY k;

	if(eficall(ST->ConIn->ReadKeyStroke, ST->ConIn, &k))
		return 0;
	return k.UnicodeChar;
}

void
usleep(int us)
{
	eficall(ST->BootServices->Stall, (UINTN)us);
}

void
unload(void)
{
	eficall(ST->BootServices->ExitBootServices, IH, MK);
}

void
memconf(char **cfg)
{
	static uchar memtype[EfiMaxMemoryType] = {
		[EfiReservedMemoryType]		2,
		[EfiLoaderCode]			1,
		[EfiLoaderData]			1,
		[EfiBootServicesCode]		2,
		[EfiBootServicesData]		2,
		[EfiRuntimeServicesCode]	2,
		[EfiRuntimeServicesData]	2,
		[EfiConventionalMemory]		1,
		[EfiUnusableMemory]		2,
		[EfiACPIReclaimMemory]		3,
		[EfiACPIMemoryNVS]		4,
		[EfiMemoryMappedIO]		2,
		[EfiMemoryMappedIOPortSpace]	2,
		[EfiPalCode]			2,
	};
	static UINT32 entvers;
	EFI_MEMORY_DESCRIPTOR *t;
	uchar *p, m;
	UINTN n;
	char *s;

	mapsize = sizeof(mapbuf);
	entsize = sizeof(EFI_MEMORY_DESCRIPTOR);
	entvers = 1;
	if(eficall(ST->BootServices->GetMemoryMap, &mapsize, mapbuf, &MK, &entsize, &entvers))
		return;

	havemap = 1;

	/* only called to get MK for ExitBootServices() */
	if(cfg == nil)
		return;

	s = *cfg;
	/*
	 * n, not mapsize: the walk used to consume mapsize, which left
	 * memtopat() below with nothing to walk.
	 */
	for(p = mapbuf, n = mapsize; n >= entsize; p += entsize, n -= entsize){
		t = (EFI_MEMORY_DESCRIPTOR*)p;

		m = 0;
		if(t->Type < EfiMaxMemoryType)
			m = memtype[t->Type];

		if(m == 0)
			continue;

		if(s == *cfg)
			memmove(s, "*e820=", 6), s += 6;
		s = hexfmt(s, 1, m), *s++ = ' ';
		s = hexfmt(s, 16, t->PhysicalStart), *s++ = ' ';
		s = hexfmt(s, 16, t->PhysicalStart + t->NumberOfPages * 4096ULL), *s++ = ' ';
	}
	*s = '\0';
	if(s > *cfg){
		s[-1] = '\n';
		/* print(*cfg); -- no printing allowed, can change MK */
		*cfg = s;
	}
}

static void
acpiconf(char **cfg)
{
	static EFI_GUID ACPI_20_TABLE_GUID = {
		0x8868e871, 0xe4f1, 0x11d3,
		0xbc, 0x22, 0x00, 0x80,
		0xc7, 0x3c, 0x88, 0x81,
	};
	static EFI_GUID ACPI_10_TABLE_GUID = {
		0xeb9d2d30, 0x2d88, 0x11d3,
		0x9a, 0x16, 0x00, 0x90,
		0x27, 0x3f, 0xc1, 0x4d,
	};
	EFI_CONFIGURATION_TABLE *t;
	uintptr pa;
	char *s;
	int n;

	pa = 0;
	t = ST->ConfigurationTable;
	n = ST->NumberOfTableEntries;
	while(--n >= 0){
		if(memcmp(&t->VendorGuid, &ACPI_10_TABLE_GUID, sizeof(EFI_GUID)) == 0){
			if(pa == 0)
				pa = (uintptr)t->VendorTable;
		} else if(memcmp(&t->VendorGuid, &ACPI_20_TABLE_GUID, sizeof(EFI_GUID)) == 0)
			pa = (uintptr)t->VendorTable;
		t++;
	}

	if(pa){
		s = *cfg;
		memmove(s, "*acpi=0x", 8), s += 8;
		s = hexfmt(s, 0, pa), *s++ = '\n';
		*s = '\0';
		print(*cfg);
		*cfg = s;
	}
}


static int
topbit(ulong mask)
{
	int bit = 0;

	while(mask != 0){
		mask >>= 1;
		bit++;
	}
	return bit;
}

static int
lowbit(ulong mask)
{
	int bit = 0;

	while((mask & 1) == 0){
		mask >>= 1;
		bit++;
	}
	return bit;
}

static void
screenconf(char **cfg)
{
	static EFI_GUID EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID = {
		0x9042a9de, 0x23dc, 0x4a38,
		0x96, 0xfb, 0x7a, 0xde,
		0xd0, 0x80, 0x51, 0x6a,
	};
	EFI_GRAPHICS_OUTPUT_PROTOCOL *gop;
	EFI_HANDLE *Handles;
	UINTN Count;

	EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info;
	ulong mr, mg, mb, mx, mc;
	int i, bits, depth;
	char *s;

	Count = 0;
	Handles = nil;
	if(eficall(ST->BootServices->LocateHandleBuffer,
		ByProtocol, &EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID, nil, &Count, &Handles))
		return;

	for(i=0; i<Count; i++){
		gop = nil;
		if(eficall(ST->BootServices->HandleProtocol,
			Handles[i], &EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID, &gop))
			continue;

		if(gop == nil)
			continue;
		if((info = gop->Mode->Info) == nil)
			continue;

		switch(info->PixelFormat){
		default:
			continue;	/* unsupported */

		case PixelRedGreenBlueReserved8BitPerColor:
			mr = 0x000000ff;
			mg = 0x0000ff00;
			mb = 0x00ff0000;
			mx = 0xff000000;
			break;

		case PixelBlueGreenRedReserved8BitPerColor:
			mb = 0x000000ff;
			mg = 0x0000ff00;
			mr = 0x00ff0000;
			mx = 0xff000000;
			break;

		case PixelBitMask:
			mr = info->PixelInformation.RedMask;
			mg = info->PixelInformation.GreenMask;
			mb = info->PixelInformation.BlueMask;
			mx = info->PixelInformation.ReservedMask;
			break;
		}

		if((depth = topbit(mr | mg | mb | mx)) == 0)
			continue;

		/* make sure we have linear framebuffer */
		if(gop->Mode->FrameBufferBase == 0)
			continue;
		if(gop->Mode->FrameBufferSize == 0)
			continue;

		goto Found;
	}
	return;

Found:
	s = *cfg;
	memmove(s, "*bootscreen=", 12), s += 12;
	s = decfmt(s, 0, info->PixelsPerScanLine), *s++ = 'x';
	s = decfmt(s, 0, info->VerticalResolution), *s++ = 'x';
	s = decfmt(s, 0, depth), *s++ = ' ';

	while(depth > 0){
		if(depth == topbit(mr)){
			mc = mr;
			*s++ = 'r';
		} else if(depth == topbit(mg)){
			mc = mg;
			*s++ = 'g';
		} else if(depth == topbit(mb)){
			mc = mb;
			*s++ = 'b';
		} else if(depth == topbit(mx)){
			mc = mx;
			*s++ = 'x';
		} else {
			break;
		}
		bits = depth - lowbit(mc);
		s = decfmt(s, 0, bits);
		depth -= bits;
	}
	*s++ = ' ';

	*s++ = '0', *s++ = 'x';
	s = hexfmt(s, 0, gop->Mode->FrameBufferBase), *s++ = '\n';
	*s = '\0';

	print(*cfg);
	*cfg = s;
}

/*
 * The top of the contiguous usable run that contains base.
 *
 * Not the highest usable address anywhere, which is what this used to
 * answer and which is wrong in a way that matters: a kernel whose
 * confinit() claims one range from the bottom of memory to that top
 * has claimed every reserved hole in between -- the ACPI tables, the
 * firmware's runtime services, anything the map calls unusable.  On
 * QEMU those sit near the top and nothing allocates that far, which is
 * exactly the "surviving only because nothing had allocated that far
 * up yet" the riscv boards were caught by.  A real machine's map is not
 * one clean run and claiming its holes is a fault rather than a
 * survivable overwrite.
 *
 * The walk makes no assumption about the order of the map: it starts
 * with the descriptor holding base and then looks for a usable
 * descriptor that begins exactly where the run so far ends, repeatedly.
 * The map is small and this is once.
 */
uvlong
memtopat(uvlong base, int *stoptype)
{
	EFI_MEMORY_DESCRIPTOR *t;
	uchar *p;
	UINTN n;
	uvlong top, end;
	int grew;

	*stoptype = -1;
	if(!havemap || mapsize == 0 || entsize == 0)
		return 0;
	top = 0;
	for(p = mapbuf, n = mapsize; n >= entsize; p += entsize, n -= entsize){
		t = (EFI_MEMORY_DESCRIPTOR*)p;
		if(t->Type >= EfiMaxMemoryType || mine[t->Type] != 1)
			continue;
		end = t->PhysicalStart + t->NumberOfPages*4096ULL;
		if(base >= t->PhysicalStart && base < end){
			top = end;
			break;
		}
	}
	if(top == 0)
		return 0;
	do {
		grew = 0;
		for(p = mapbuf, n = mapsize; n >= entsize; p += entsize, n -= entsize){
			t = (EFI_MEMORY_DESCRIPTOR*)p;
			if(t->Type >= EfiMaxMemoryType || mine[t->Type] != 1)
				continue;
			if(t->PhysicalStart != top)
				continue;
			top = t->PhysicalStart + t->NumberOfPages*4096ULL;
			grew = 1;
			break;
		}
	} while(grew);

	/*
	 * What the run ran into, for the report.  -1 means the map has
	 * nothing at all at that address, which is the top of memory;
	 * anything else is the EFI type of whatever is in the way, and on
	 * a real machine that is the interesting fact.
	 */
	for(p = mapbuf, n = mapsize; n >= entsize; p += entsize, n -= entsize){
		t = (EFI_MEMORY_DESCRIPTOR*)p;
		if(t->PhysicalStart == top){
			*stoptype = t->Type;
			break;
		}
	}
	return top;
}

void
eficonfig(char **cfg)
{
	/* memconf(cfg); -- must be called right before unload() */
	acpiconf(cfg);
	screenconf(cfg);
}

EFI_STATUS
efimain(EFI_HANDLE ih, EFI_SYSTEM_TABLE *st)
{
	char path[MAXPATH], *kern;
	void *f;

	IH = ih;
	ST = st;

	f = nil;
#ifdef AA64
	/*
	 * Only the filesystem.  pxe.c wants the x86 PXE protocols, and
	 * iso.c reads an ISO9660 directory entry whose 32-bit fields sit
	 * at odd offsets -- which 7c will not compile for arm64 at all
	 * ("isowalk: odd offset: 42"), because the instruction it wants
	 * does not exist there.  Neither is a way anyone boots an arm64
	 * machine.
	 */
	if(fsinit(&f))
		print("no boot devices\n");
#else
	if(pxeinit(&f) && isoinit(&f) && fsinit(&f))
		print("no boot devices\n");
#endif

	open = rebase(open);
	read = rebase(read);
	close = rebase(close);
	if(stop) stop = rebase(stop);

	for(;;){
		kern = configure(f, path);
		f = open(kern);
		if(f == nil){
			print("not found\n");
			continue;
		}
		print(bootkern(f));
		print("\n");
		close(f);
		f = nil;
	}
}
