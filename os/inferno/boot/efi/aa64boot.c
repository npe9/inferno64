#include <u.h>
#include "fns.h"
#include "mem.h"
#include "efi.h"

/*
 * The arm64 half of the EFI loader: the entry into C, the two symbols
 * the x86 loaders get from their own assembly, and the device tree.
 *
 * The shape of the loader is otherwise shared -- efi.c for the console
 * and the configuration table, fs.c for the filesystem, sub.c for the
 * a.out and the handoff -- and the three things that cannot be shared
 * are here.
 */

extern void *imagehandle;		/* stored by start in aa64.s */
extern EFI_STATUS efimain(EFI_HANDLE, EFI_SYSTEM_TABLE*);

/*
 * Where the configuration string lives.  On x86 this is the fixed low
 * address CONFADDR, 0x1200, because that is where a 9front or Inferno
 * pc kernel goes looking for it.  arm64 has no low memory to put it in
 * -- QEMU's virt machine starts RAM at 0x40000000 and UEFI has nothing
 * mapped below it -- and no arm64 kernel in this tree reads a
 * configuration block at all, so it goes in the loader's own bss.
 * Writing it to 0x1200 was a data abort, which is the only reason this
 * needed finding out.
 */
static char confbuf[4096];
char *confaddr = confbuf;

/*
 * jump() takes the entry from here rather than as its argument, the way
 * the x86 loaders do, because bootkern() stages it before calling
 * unload() and nothing may touch the firmware after that.
 */
void *jumpentry;

/*
 * The device tree, from the EFI configuration table.
 *
 * A kernel this tree builds for arm64 expects a DTB pointer in x0 and
 * finds its UART, its GIC, its virtio windows and its PCI ECAM window
 * through it.  UEFI has one to give only when the firmware was told to
 * publish it: QEMU's ArmVirtQemu build decides between ACPI and a
 * device tree and hands over whichever it chose, so this is present
 * under -machine virt,acpi=off and absent under the default.  Absent,
 * the loader says so rather than handing the kernel a null pointer and
 * letting it fail four functions later looking for a uart.
 *
 * The ACPI case is the one a real SystemReady machine presents, and it
 * is not handled here: see acpiconf() in efi.c, which already finds the
 * RSDP the same way, and doc/inferno-driver-plan.ms for what reading
 * MADT and IORT still needs.
 */
void*
dtb(void)
{
	static EFI_GUID EFI_DTB_TABLE_GUID = {
		0xb1b621d5, 0xf19c, 0x41a5,
		0x83, 0x0b, 0xd9, 0x15,
		0x2c, 0x69, 0xaa, 0xe0,
	};
	EFI_CONFIGURATION_TABLE *t;
	int n;

	t = ST->ConfigurationTable;
	for(n = ST->NumberOfTableEntries; --n >= 0; t++)
		if(memcmp(&t->VendorGuid, &EFI_DTB_TABLE_GUID, sizeof(EFI_GUID)) == 0)
			return t->VendorTable;
	return nil;
}

/*
 * Claim the memory the kernel links at, before writing a byte of it.
 *
 * AllocateAddress asks for one address and nothing else, so a refusal
 * means the firmware has that range and the load would have corrupted
 * it.  Without this the loader wrote the kernel wherever the a.out said
 * and found out whether that mattered after ExitBootServices, which is
 * after the last place anything can be printed.
 */
int
claim(void *at, uintptr len)
{
	EFI_PHYSICAL_ADDRESS pa;
	UINTN pages;

	pa = (EFI_PHYSICAL_ADDRESS)(uintptr)at;
	pages = (len + BY2PG-1) / BY2PG;
	if(eficall(ST->BootServices->AllocatePages,
		(UINTN)AllocateAddress, (UINTN)EfiLoaderData, pages, &pa) != 0)
		return -1;
	return 0;
}

/*
 * start in aa64.s calls this with one argument because kencc wants a
 * second one in the caller's outgoing argument area, and start has no
 * frame to put it in.  The image handle comes through a global instead.
 */
EFI_STATUS
efistart(EFI_SYSTEM_TABLE *st)
{
	return efimain((EFI_HANDLE)imagehandle, st);
}
