#include <u.h>
#include "fns.h"
#include "efi.h"

UINTN MK;
/*
 * The highest address the firmware calls usable, from the memory map.
 * Written by memconf() and read only by the arm64 path, which has
 * nowhere else to learn it when there is no device tree.
 */
uvlong memtop;
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
	/*
	 * static, not automatic, and for two reasons.  A 96K map buffer
	 * on the firmware's own stack is a lot to ask of it; and 7c
	 * cannot pass the address of a stack local as an argument to a
	 * variadic function on arm64 -- it emits a DWORD of a stack
	 * address-constant and 7l refuses it as "illegal combination
	 * DWORD NONE NONE LACON".  The addresses of statics are
	 * $sym(SB) and assemble.
	 */
	static UINTN mapsize, entsize;
	static UINT32 entvers;
	static uchar mapbuf[96*1024];
	EFI_MEMORY_DESCRIPTOR *t;
	uchar *p, m;
	uvlong top;
	UINTN n;
	char *s;

	mapsize = sizeof(mapbuf);
	entsize = sizeof(EFI_MEMORY_DESCRIPTOR);
	entvers = 1;
	if(eficall(ST->BootServices->GetMemoryMap, &mapsize, mapbuf, &MK, &entsize, &entvers))
		return;

	/*
	 * The top of usable memory, before anything else: this is the
	 * one number an arm64 kernel needs and cannot get anywhere else
	 * when the firmware publishes ACPI and no device tree.  Computed
	 * even when the caller wants only MK, because that is exactly
	 * the arm64 call.  Types the memtype table calls 1 are the ones
	 * that are the guest's after ExitBootServices.
	 */
	for(p = mapbuf, n = mapsize; n >= entsize; p += entsize, n -= entsize){
		t = (EFI_MEMORY_DESCRIPTOR*)p;
		if(t->Type >= EfiMaxMemoryType || memtype[t->Type] != 1)
			continue;
		top = t->PhysicalStart + t->NumberOfPages*4096ULL;
		if(top > memtop)
			memtop = top;
	}

	/* only called to get MK for ExitBootServices() */
	if(cfg == nil)
		return;

	s = *cfg;
	for(p = mapbuf; mapsize >= entsize; p += entsize, mapsize -= entsize){
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
