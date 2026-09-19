#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"

/*
mmu.c: differs between pc and pc64
	- on 9front:
	pmap() - setup up page table entries for the physical address in virtual memory
			the virtual memory address is a parameter
			the flags are included in the physical address
			used by memory.c:^mapkzero for setting the page tables of the kernel
	vmap() - setup page tables for device memory
			virtual memory address = device memory address
			used by almost all the device drivers accessing registers
				as memory addresses (unbacked physical address)
	kmap() - setup kernel page tables
			virtual memory address = page address + KMAP
	A process's virtual memory usage is maintained in the PMMU data structure
		on inferno:
	1. there is no separate virtual memory address - linear mapping
	2. As all memory is linear and global, there is no need to maintain
		a per-process list of page tables
	3. pmap() without the parameter for the virtual memory address handles the
		above needs
	3. vmap() is  a wrapper around pmap() specialized for unbacked physical
		addresses
	4. kmap() is obsolete
 */
#define DP	if(1){}else print
/*
 * Simple segment descriptors with no translation.
 */
#define	EXECSEGM(p) 	{ 0, SEGL|SEGP|SEGPL(p)|SEGEXEC }
#define	DATASEGM(p) 	{ 0, SEGB|SEGG|SEGP|SEGPL(p)|SEGDATA|SEGW }

Segdesc gdt[NGDT] =
{
[NULLSEG]	{ 0, 0},		/* null descriptor */
[KESEG]		EXECSEGM(0),		/* code - kernel privilege for all */
[KDSEG]		DATASEGM(0),		/* data - kernel privilege for all */
};

enum {
	/* level */
	PML4E	= 3,
	PDPE	= 2,
	PDE	= 1,
	PTE	= 0,
};

static void
loadptr(u16int lim, uintptr off, void (*load)(void*))
{
	u64int b[2], *o;
	u16int *s;

	o = &b[1];
	s = ((u16int*)o)-1;

	*s = lim;
	*o = off;

	(*load)(s);
}

static void
taskswitch(uintptr stack)
{
	Tss *tss;

	tss = m->tss;
	tss->rsp0[0] = (u32)stack;
	tss->rsp0[1] = stack >> 32;
	tss->rsp1[0] = (u32)stack;
	tss->rsp1[1] = stack >> 32;
	tss->rsp2[0] = (u32)stack;
	tss->rsp2[1] = stack >> 32;
	mmuflushtlb();
}

void
mmuinit(void)
{
	uintptr x;
	int i;

	/* move kernelro here to mimic 9front? */

	m->tss = mallocz(sizeof(Tss), 1);
	if(m->tss == nil){
		print("mmuinit: no memory for Tss");
		panic("mmuinit: no memory for Tss");
	}
	m->tss->iomap = 0xDFFF;
	/* the IST is not used by the interrupt descriptors.
	 * Putting the existing stack address instead of
	 * leaving the fields empty.
	 */
	for(i=0; i<14; i+=2){
		x = (uintptr)m + MACHSIZE;
		m->tss->ist[i] = x;
		m->tss->ist[i+1] = x>>32;
	}

	/*
	 * We used to keep the GDT in the Mach structure, but it
	 * turns out that that slows down access to the rest of the
	 * page.  Since the Mach structure is accessed quite often,
	 * it pays off anywhere from a factor of 1.25 to 2 on real
	 * hardware to separate them (the AMDs are more sensitive
	 * than Intels in this regard).  Under VMware it pays off
	 * a factor of about 10 to 100.
	 */
	memmove(m->gdt, gdt, sizeof gdt);

	x = (uintptr)m->tss;
	m->gdt[TSSSEG+0].d0 = (x<<16)|(sizeof(Tss)-1);
	m->gdt[TSSSEG+0].d1 = (x&0xFF000000)|((x>>16)&0xFF)|SEGTSS|SEGPL(0)|SEGP;
	m->gdt[TSSSEG+1].d0 = x>>32;
	m->gdt[TSSSEG+1].d1 = 0;

	if(0){
		print("GDT: m 0x%p m+MACHSIZE 0x%p\n", m, (uintptr)m+MACHSIZE);
		for(i=0; i<NGDT; i++){
			print("	i %d d0 0x%ux d1 0x%ux\n", i, m->gdt[i].d0, m->gdt[i].d1);
		}
	}

	loadptr(sizeof(gdt)-1, (uintptr)m->gdt, lgdt);
	loadptr(sizeof(Segdesc)*512-1, (uintptr)IDTADDR, lidt);
	taskswitch((uintptr)m + MACHSIZE);
	ltr(TSSSEL);

	wrmsr(FSbase, 0ull);
	wrmsr(GSbase, (u64)&machp[m->machno]);
	/* SWAPGS is not needed for inferno.
	 * leaving it the same as GSbase if unintentional SWAPGS's are used
	 */
	wrmsr(KernelGSbase, (u64)&machp[m->machno]);

	/* pre allocate pages */
	Confmem *cm;

	for(i=0; i<nelem(conf.mem); i++){
		cm = &conf.mem[i];
		if(cm->npage == 0)
			continue;
		DP("i %d base 0x%zx npage 0x%zx %zd\n", i, cm->base, cm->npage, cm->npage);
		pmap(cm->base, PTEGLOBAL|PTEWRITE|PTENOEXEC|PTEVALID, cm->npage*BY2PG);
	}
}

int
mmukmapsync(uintptr va)
{
USED(va);
return 0;
}

uintptr
mmukmap(uintptr pa, uintptr va, int size)
{
USED(pa, va, size);
return 0;
}

/*
 * Add a device mapping to the vmap range.
 * note that the VMAP and KZERO PDPs are shared
 * between processors (see mpstartap) so no
 * synchronization is being done.
 *
 * < cinap_lenrek> joe7: pmap() is kind of generic function,
 *  allowing to pass the protection flags too
 * < cinap_lenrek> vmap() and kmap() are all built ontop of it
 */
/*
 * The largest physical address vmap() will map.  This kernel's mapping
 * is the identity, so a physical address is also the virtual address it
 * is reached at, and two things bound it: what the processor can
 * address physically -- CPUID 80000008H, EAX bits 7..0 -- and what the
 * four-level page table this kernel builds can name, which is the low
 * canonical half, 2**47.
 *
 * It used to be the constant VMAPSIZE, 512 GiB, and that is below where
 * OVMF puts a 64-bit BAR on q35: an NVMe controller's BAR0 landed at
 * 0xc000000000, vmap() refused it, and the driver printed "nvme: can't
 * vmap bar0" and did not attach.  Every cloud machine boots UEFI and
 * every one of them can put a BAR up there, so the ceiling has to come
 * from the machine rather than from a number in mem.h.
 *
 * Computed once, on the first vmap(), because cpuidentify() runs before
 * any of them and a machine's physical address width does not change.
 */
static uvlong vmaplimit;
/*
 * 2 MiB pages in pmap(), on.  *pmaplarge=0 turns them off.
 *
 * Sixteen gibibytes in 4 KiB entries is four million of them and about
 * thirty-two mebibytes of page tables; in 2 MiB entries it is eight
 * thousand.  Measured on a 16 GiB guest: 7942 large pages and 229543
 * small ones, where the small-page kernel built 4.1 million.  At a
 * terabyte the 4 KiB arithmetic stops being a preference.
 *
 * Three things had to be true first, and each was found by being
 * wrong:
 *
 *	mmuwalk() must not follow a large entry as though it named a
 *	table.  It did, read the mapped memory as entries and wrote new
 *	ones into it; the pool overlap checker in port/alloc.c caught
 *	the image pool's chain leader holding "magic 0x2103", a PTE
 *	with flags 0x103 where MAGIC_E belongs.  It splits now.
 *
 *	The split has to trigger at the right level.  The first version
 *	tested i > level, and a 2 MiB entry is read at i == level == 0,
 *	so it never ran and the corruption was unchanged.
 *
 *	Mapping a range twice has to be free.  meminit() maps each bank
 *	before taking it, so the second pass fell through to the 4 KiB
 *	path, whose walk split the very page it was about to rebuild:
 *	eight thousand splits and a TLB flush apiece, which is a boot
 *	that stops in meminit with nothing printed.
 *
 * The check that says it is right is a boot at -m 16384 with the
 * overlap checker silent, and 512 MiB and 4 GiB boots beside it.
 *
 * Off by default, and the question is open rather than settled.
 *
 * Eight Compute Engine instances, four Cascade Lake Xeons each, the
 * soak workload run for the same number of guest ticks.  Throughput is
 * Dis quanta per tick:
 *
 *	4 KiB   645218 641568 643699 656055   (2.3 per cent apart)
 *	2 MiB   651979 663286 511658 471310
 *
 * Two large-page runs at or just above every small-page run, and two a
 * quarter below.  Every instance reported the same processor, stepping
 * and clock to within three per cent, and all four large-page runs
 * built exactly 7936 large and 231024 small pages, so neither the
 * silicon nor the mapping varies.
 *
 * An earlier version of this comment divided the work by the quanta it
 * took, got eight runs inside a 3.5 per cent band, and concluded the
 * two arms were indistinguishable.  That was wrong, and wrong in a way
 * worth recording: a Dis quantum is a slice of Dis work and chantest
 * does a fixed amount of it, so chantest-per-quantum is a constant of
 * the program and cannot move with machine speed.  Booting the same
 * kernel on an idle laptop and then on a deliberately loaded one:
 * quanta per tick fell from 35.9 to 19.5, a 46 per cent drop, while
 * chantest per million quanta went 557.10 to 551.47, one per cent.  The
 * normaliser divided out precisely the quantity large pages would
 * change.
 *
 * So the default stays where the unnormalised evidence puts it, and the
 * experiment that settles it is a paired one: alternate *pmaplarge=0
 * and *pmaplarge=1 boots on a single instance, so that host speed is
 * common to both halves of each pair and a difference that follows the
 * flag is the kernel.  Unpaired arms on separate instances cannot tell
 * those apart at this sample size.
 *
 * What large pages certainly buy, and what makes the question worth
 * settling: 38 times fewer entries and about 71 MiB of page tables
 * given back on a 16 GiB machine.
 */
int pmaplarge = 0;	/* *pmaplarge=1 turns 2 MiB pages on; see above */
ulong npmaplarge, npmapsmall, npmapsplit, npmapmixed;	/* what pmap() built */

/*
 * Does one memory type cover the whole of [pa, pa+len)?
 *
 * A 2 MiB page carries a single cache attribute for its whole extent,
 * so mapping one across an MTRR boundary makes the processor pick, and
 * what it picks for a mixed range is the strongest type present -- an
 * uncached window two megabytes wide where half of it was writeback.
 * That would cost far more than the TLB saves.  The type is allowed to
 * change so long as it changes to the same name, which is what two
 * adjacent variable ranges that both say wb look like from here.
 *
 * No MTRRs at all means nothing to straddle.
 *
 * In practice this never fires for RAM and is not meant to: e820scan()
 * calls mtrrexclude(MemRAM, "wb") before it maps anything, which moves
 * every non-writeback piece of RAM out of MemRAM, so what pmap() is
 * handed is uniform by construction.  meminit() reports the count and
 * whether the MTRRs were readable at all, and a 16 GiB boot says "0
 * mixed-type (mtrr at 1M wb to 0xc0000000)" -- readable, and nothing to
 * refuse.  The guard is here for the next caller that maps something
 * other than RAM this way.
 */
static int
onetype(uintptr pa, uintptr len)
{
	u64 next, end;
	char *first, *a;

	next = 0;
	first = mtrrattr(pa, &next);
	if(first == nil)
		return 1;
	end = pa + len;
	while(next < end){
		if(next <= pa)		/* no progress: do not trust it */
			return 0;
		pa = next;
		a = mtrrattr(pa, &next);
		if(a == nil || strcmp(a, first) != 0)
			return 0;
	}
	return 1;
}

static void
vmaplimitinit(void)
{
        u32 regs[4];
        int bits;

        /*
         * 36 is the architectural minimum for a processor with PAE, and
         * is what to assume if the extended leaf is not there at all.
         */
        bits = 36;
        cpuid(0x80000000, 0, regs);
        if(regs[0] >= 0x80000008){
                cpuid(0x80000008, 0, regs);
                if((regs[0] & 0xff) != 0)
                        bits = regs[0] & 0xff;
        }
        if(bits > 47)
                bits = 47;
        vmaplimit = 1ull << bits;
        if(vmaplimit < VMAPSIZE)
                vmaplimit = VMAPSIZE;
}

void*
vmap(uintptr pa, s32 size)
{
        int o;

        if(vmaplimit == 0)
                vmaplimitinit();
        if(pa < BY2PG || size <= 0 || -pa < size || pa+size > vmaplimit){
                print("vmap pa=%llux size=%d limit=%llux pc=%#p\n",
                        pa, size, vmaplimit, getcallerpc(&pa));
                return nil;
        }

        /*
         * might be asking for less than a page.
         */
        o = pa & (BY2PG-1);
        pa -= o;
        size += o;
        pmap(pa, PTEGLOBAL|PTEUNCACHED|PTEWRITE|PTENOEXEC|PTEVALID, size);
        return (void*)(pa+o);
}

void
vunmap(void *va, s32 size)
{
USED(va, size);
/* nothing to do */
}

int
segflush(void*, ulong)
{
	return 0;
}

static uintptr*
mmucreate(uintptr *table, uintptr pa, int level, int index)
{
	uintptr *page, flags;
	
	DP("mmucreate table 0x%p pa 0x%p level %d index %d\n",
		table, pa, level, index);
	flags = PTEWRITE|PTEVALID;
	page = (uintptr*)rampage();
	DP("mmucreate new page 0x%p PTSZ 0x%x %d BY2PG 0x%zx %zd\n",
		page, PTSZ, PTSZ, BY2PG, BY2PG);
	memset(page, 0, PTSZ);
	table[index] = PADDR(page) | flags;
	return page;
}

/* not bothering with 1GiB or 2MiB pages yet */
uintptr*
mmuwalk(uintptr* table, uintptr pa, int level, int create)
{
	uintptr pte /*, flags*/;
	int i, x;

	DP("mmuwalk table 0x%p pa 0x%p level %d create %d\n",
		table, pa, level, create);
	/* flags = PTEWRITE | PTEVALID; */
	x = PTLX(pa, 3);
	DP("\tpml4 index %d\n", x);
	for(i = 2; i >= level; i--){
		pte = table[x];
		if(pte & PTEVALID){
			/*
			 * A large page is not a table.  Following one as
			 * though it were walks into the memory it maps: the
			 * entries read back are whatever those bytes happen
			 * to be, and with create set this writes page-table
			 * entries into somebody's heap.  Measured, not
			 * feared -- the pool overlap checker in
			 * os/inferno/port/alloc.c caught the image pool's
			 * chain leader holding "magic 0x2103", a PTE with
			 * flags 0x103 where MAGIC_E belongs.
			 *
			 * The entry read at iteration i maps PGLSZ(i+1) and
			 * stands for 512 entries of PGLSZ(i), so descending
			 * below it means writing those out and putting the
			 * table in its place.  Same physical range, same
			 * flags: every mapping the large page provided still
			 * holds when this returns, which is what makes the
			 * split safe to do underneath a caller that knows
			 * nothing about it.
			 *
			 * The level-0 entries are ordinary pages and must
			 * NOT carry PTESIZE; at any higher level the pieces
			 * are themselves large pages and must.  Getting that
			 * boundary wrong is how the first attempt at this
			 * failed -- it tested i > level, so the 2 MiB case,
			 * which is read at i == level == 0, never split at
			 * all and the corruption stayed exactly as it was.
			 */
			if((pte & PTESIZE) != 0){
				uintptr *split, base, pflags, off;

				if(!create)
					return 0;
				base = PPN(pte);
				pflags = pte & ~(PPN(pte) | PTESIZE);
				split = (uintptr*)rampage();
				for(off = 0; off < (1<<PTSHIFT); off++)
					split[off] = (base + off*PGLSZ(i))
						| pflags | (i > 0 ? PTESIZE : 0);
				table[x] = PADDR(split) | PTEWRITE|PTEVALID;
				npmapsplit++;
				/*
				 * The old entry may be in this processor's
				 * TLB as one large translation; the new ones
				 * are not the same entry.  Cheap here and
				 * correct: a split during boot has no other
				 * processor to tell, and one after does --
				 * see the note at pmaplarge.
				 */
				mmuflushtlb();
				table = split;
			} else {
				pte = PPN(pte);
				table = (void*)pte;
			}
		} else {
			if(!create)
				return 0;
			table = mmucreate(table, pa, i, x);
		}
		x = PTLX(pa, i);
		DP("\tlevel %d index %d\n", i, x);
	}
	return &table[x];
}

static int
ptecount(uintptr pa, s32 level)
{
	return (1<<PTSHIFT) - (pa & PGLSZ(level+1)-1) / PGLSZ(level);
}

/* splits a 2 MiB page table entry into a table of 4096 pages
 * probably not useful for inferno
 */
static void
ptesplit(uintptr* table, uintptr va)
{
	uintptr *pte, pa, off;

	pte = mmuwalk(table, va, 1, 0);
	if(pte == nil || (*pte & PTESIZE) == 0 || (va & PGLSZ(1)-1) == 0)
		return;
	table = (uintptr*)rampage();
	va &= -PGLSZ(1);
	pa = *pte & ~PTESIZE;
	for(off = 0; off < PGLSZ(1); off += PGLSZ(0))
		table[PTLX(va + off, 0)] = pa + off;
	*pte = PADDR(table) | PTEVALID|PTEWRITE;
	invlpg(va);
}

void
pmap(uintptr pa, u64 flags, s64 size)
{
	uintptr *pte, *ptee;
	s32 z, l;

	if(size <= 0)
		panic("pmap: pa=%#zux size=%lld", pa, size);
	DP("pmap pa 0x%zux-0x%zux flags 0x%llux size %llud 0x%llux\n",
		pa, (uintptr)pa+size, flags, size, size);
	pa = PPN(pa);
	DP("\tpa 0x%zux\n", pa);
	while(size > 0){
		/*
		 * A 2 MiB page where the range allows one.
		 *
		 * This used to say "reducing complexity, use 4096 byte
		 * pages all through", and that is why mapkzero() refuses
		 * RAM above 1 GiB: sixteen gibibytes of 4 KiB entries is
		 * four million PTEs and 32 MiB of page tables out of the
		 * early allocator, before there is an allocator.  The same
		 * range in 2 MiB entries is eight thousand.
		 *
		 * Only when the physical address and what is left are both
		 * 2 MiB aligned, and only into a page-directory entry that
		 * is empty: one that is already valid points at a table of
		 * 4 KiB pages that l.s or an earlier call built, and
		 * replacing it with a large page would orphan them.
		 */
		l = 0;
		z = PGLSZ(0);
		if(pmaplarge && (pa & (PGLSZ(1)-1)) == 0 && size >= (s64)PGLSZ(1)
		&& !onetype(pa, PGLSZ(1)))
			npmapmixed++;
		else if(pmaplarge && (pa & (PGLSZ(1)-1)) == 0 && size >= (s64)PGLSZ(1)){
			pte = mmuwalk(m->pml4, pa, 1, 1);
			if(pte != nil && (*pte & PTEVALID) == 0){
				*pte = pa | flags | PTESIZE;
				npmaplarge++;
				pa += PGLSZ(1);
				size -= PGLSZ(1);
				continue;
			}
			/*
			 * Already a large page for this very address: mapping
			 * a range twice has to be free.  Without this the
			 * second call falls through to the 4 KiB path, whose
			 * walk splits the page it is about to re-create --
			 * eight thousand splits, eight thousand pages out of
			 * rampage() and a TLB flush apiece, for a bank of
			 * thirteen gibibytes.  meminit() maps each bank
			 * before it takes it, so every bank is mapped twice
			 * and that is exactly what it did: the boot stopped
			 * in meminit with no message.
			 */
			if(pte != nil && (*pte & PTESIZE) != 0
			&& PPN(*pte) == pa){
				pa += PGLSZ(1);
				size -= PGLSZ(1);
				continue;
			}
		}
		pte = mmuwalk(m->pml4, pa, l, 1);
		if(pte == nil){
			panic("pmap: pa=%#p size=%lld", pa, size);
		}
		ptee = pte + ptecount(pa, l);
		while(size > 0 && pte < ptee){
			npmapsmall++;
			*pte++ = pa | flags;
			pa += z;
			size -= z;
		}
	}
}

void
punmap(uintptr pa, uvlong size)
{
	uintptr *pte;
	int l;

	pa = PPN(pa);
	while(size > 0){
		if((pa % PGLSZ(1)) != 0 || size < PGLSZ(1))
			ptesplit((uintptr*)PML4ADDR, pa);
		l = 0;
		pte = mmuwalk((uintptr*)PML4ADDR,pa, l, 0);
		if(pte == nil && (pa % PGLSZ(1)) == 0 && size >= PGLSZ(1))
			pte = mmuwalk((uintptr*)PML4ADDR, pa, ++l, 0);
		if(pte){
			*pte = 0;
			invlpg(pa);
		}
		pa += PGLSZ(l);
		size -= PGLSZ(l);
	}
}

/*
 * mark pages as write combining (used for framebuffer)
 */
void
patwc(void *a, int n)
{
	uintptr *pte, mask, attr, pa;
	int z, l;
	vlong v;

	/* check if pat is usable */
	if((MACHP(0)->cpuiddx & Pat) == 0
	|| rdmsr(0x277, &v) == -1
	|| ((v >> PATWC*8) & 7) != 1)
		return;

	/* set the bits for all pages in range */
	for(pa = (uintptr)a; n > 0; n -= z, pa += z){
		l = 0;
		pte = mmuwalk((uintptr*)PML4ADDR, pa, l, 0);
		if(pte == 0)
			pte = mmuwalk((uintptr*)PML4ADDR, pa, ++l, 0);
		if(pte == 0 || (*pte & PTEVALID) == 0)
			panic("patwc: pa=%#p", pa);
		z = PGLSZ(l);
		z -= pa & (z-1);
		mask = l == 0 ? 3<<3 | 1<<7 : 3<<3 | 1<<12;
		attr = (((PATWC&3)<<3) | ((PATWC&4)<<5) | ((PATWC&4)<<10));
		*pte = (*pte & ~mask) | (attr & mask);
	}
}
