/*
 *	Definitions needed for  accessing Irix ELF headers
 *
 *	Every field below is a fixed-width word in the file, so none of
 *	them may be `ulong': that is eight bytes on the hosts these
 *	tools are built on and four in the record.  See AGENTS.md on
 *	`long' is 32 bits.
 */
typedef struct {
	uchar	ident[16];	/* ident bytes */
	ushort	type;		/* file type */
	ushort	machine;	/* target machine */
	int	version;	/* file version */
	u32	elfentry;	/* start address */
	u32	phoff;		/* phdr file offset */
	u32	shoff;		/* shdr file offset */
	int	flags;		/* file flags */
	ushort	ehsize;		/* sizeof ehdr */
	ushort	phentsize;	/* sizeof phdr */
	ushort	phnum;		/* number phdrs */
	ushort	shentsize;	/* sizeof shdr */
	ushort	shnum;		/* number shdrs */
	ushort	shstrndx;	/* shdr string index */
} Ehdr;

typedef struct {
	int	type;		/* entry type */
	u32	offset;		/* file offset */
	u32	vaddr;		/* virtual address */
	u32	paddr;		/* physical address */
	int	filesz;		/* file size */
	u32	memsz;		/* memory size */
	int	flags;		/* entry flags */
	int	align;		/* memory/file alignment */
} Phdr;

/*
 * The 64-bit forms.  Same fields, wider: an ELF64 header is 64 bytes
 * and a program header 56, against 52 and 32.  Every board in this
 * tree but pc64 and armv7 links its kernel as ELF64, with the Plan 9
 * symbol table in a PT_NULL program header exactly as the 32-bit
 * loaders write it, so this is what lets libmach say anything at all
 * about them.
 */
typedef struct {
	uchar	ident[16];	/* ident bytes */
	ushort	type;		/* file type */
	ushort	machine;	/* target machine */
	u32	version;	/* file version */
	uvlong	elfentry;	/* start address */
	uvlong	phoff;		/* phdr file offset */
	uvlong	shoff;		/* shdr file offset */
	u32	flags;		/* file flags */
	ushort	ehsize;		/* sizeof ehdr */
	ushort	phentsize;	/* sizeof phdr */
	ushort	phnum;		/* number phdrs */
	ushort	shentsize;	/* sizeof shdr */
	ushort	shnum;		/* number shdrs */
	ushort	shstrndx;	/* shdr string index */
} Ehdr64;

typedef struct {
	u32	type;		/* entry type */
	u32	flags;		/* entry flags */
	uvlong	offset;		/* file offset */
	uvlong	vaddr;		/* virtual address */
	uvlong	paddr;		/* physical address */
	uvlong	filesz;		/* file size */
	uvlong	memsz;		/* memory size */
	uvlong	align;		/* memory/file alignment */
} Phdr64;

typedef struct {
	u32	name;		/* section name */
	u32	type;		/* SHT_... */
	u32	flags;		/* SHF_... */
	u32	addr;		/* virtual address */
	u32	offset;		/* file offset */
	u32	size;		/* section size */
	u32	link;		/* misc info */
	u32	info;		/* misc info */
	u32	addralign;	/* memory alignment */
	u32	entsize;	/* entry size if table */
} Shdr;

enum {
	/* Ehdr codes */
	MAG0 = 0,		/* ident[] indexes */
	MAG1 = 1,
	MAG2 = 2,
	MAG3 = 3,
	CLASS = 4,
	DATA = 5,
	VERSION = 6,

	ELFCLASSNONE = 0,	/* ident[CLASS] */
	ELFCLASS32 = 1,
	ELFCLASS64 = 2,
	ELFCLASSNUM = 3,

	ELFDATANONE = 0,	/* ident[DATA] */
	ELFDATA2LSB = 1,
	ELFDATA2MSB = 2,
	ELFDATANUM = 3,

	NOETYPE = 0,		/* type */
	REL = 1,
	EXEC = 2,
	DYN = 3,
	CORE = 4,

	NONE = 0,		/* machine */
	M32 = 1,		/* AT&T WE 32100 */
	SPARC = 2,		/* Sun SPARC */
	I386 = 3,		/* Intel 80386 */
	M68K = 4,		/* Motorola 68000 */
	M88K = 5,		/* Motorola 88000 */
	I486 = 6,		/* Intel 80486 */
	I860 = 7,		/* Intel i860 */
	MIPS = 8,		/* Mips R2000 */
	S370 = 9,		/* Amdhal	*/
	SPARC64 = 18,		/* Sun SPARC v9 */
	POWER = 20,		/* PowerPC */
	POWER64 = 21,		/* PowerPC64 */
	ARM = 40,		/* ARM */
	AMD64 = 62,		/* Amd64 */
	ARM64 = 183,		/* ARM64 */
	RISCV = 243,		/* RISC-V */

	NO_VERSION = 0,		/* version, ident[VERSION] */
	CURRENT = 1,

	/* Phdr Codes */
	NOPTYPE = 0,		/* type */
	LOAD = 1,
	DYNAMIC = 2,
	INTERP = 3,
	NOTE = 4,
	SHLIB = 5,
	PHDR = 6,

	R = 0x4,		/* flags */
	W = 0x2,
	X = 0x1,

	/* Shdr Codes */
	Progbits = 1,	/* section types */
	Strtab = 3,
	Nobits = 8,

	Swrite = 1,	/* section attributes */
	Salloc = 2,
	Sexec = 4,
};

#define	ELF_MAG		((0x7f<<24) | ('E'<<16) | ('L'<<8) | 'F')
