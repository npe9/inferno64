implement Format;

include "sys.m";
	sys: Sys;

include "draw.m";

include "daytime.m";
	daytime: Daytime;

include "disks.m";
	disks: Disks;
	Disk: import disks;

include "arg.m";

Format: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

#
#  floppy types (all MFM encoding)
#
Type: adt {
	name:	string;
	bytes:	int;	# bytes/sector
	sectors:	int;	# sectors/track
	heads:	int;	# number of heads
	tracks:	int;	# tracks/disk
	media:	int;	# media descriptor byte
	cluster:	int;	# default cluster size
};

floppytype := array[] of  {
	Type ( "3½HD",	512, 18,	2,	80,	16rf0,	1 ),
	Type ( "3½DD",	512,	  9,	2,	80,	16rf9,	2 ),
	Type ( "3½QD",	512, 36,	2,	80,	16rf9,	2 ),	# invented
	Type ( "5¼HD",	512,	15,	2,	80,	16rf9,	1 ),
	Type ( "5¼DD",	512,	  9,	2,	40,	16rfd,	2 ),
	Type	( "hard",	512,	  0,	0,	  0,	16rf8,	4 ),
};

# offsets in DOS boot area
DB_MAGIC 	: con 0;
DB_VERSION	: con 3;
DB_SECTSIZE	: con 11;
DB_CLUSTSIZE	: con 13;
DB_NRESRV	: con 14;
DB_NFATS	: con 16;
DB_ROOTSIZE	: con	17;
DB_VOLSIZE	: con	19;
DB_MEDIADESC: con 21;
DB_FATSIZE	: con 22;
DB_TRKSIZE	: con 24;
DB_NHEADS	: con 26;
DB_NHIDDEN	: con 28;
DB_BIGVOLSIZE: con 32;
DB_DRIVENO 	: con 36;
DB_RESERVED0: con 37;
DB_BOOTSIG	: con 38;
DB_VOLID	: con 39;
DB_LABEL	: con 43;
DB_TYPE		: con 54;

DB_VERSIONSIZE: con 8;
DB_LABELSIZE	: con 11;
DB_TYPESIZE	: con 8;
DB_SIZE		: con 62;

#
# FAT32's boot sector, which is not the one above with fields added.
#
# From offset 36 on it is a different layout: the 16-bit sectors-per-FAT
# at DB_FATSIZE and the root-entry count at DB_ROOTSIZE are both written
# as zero and the real values live here, and the whole extended block --
# drive number, boot signature, volume id, label, type string -- moves
# from 36 to 64.  Writing a FAT32 with the extended block still at 36 is
# the mistake that produces a filesystem which looks complete, has every
# field, and is refused by everything, because each one is in the place
# the other format uses.
#
DB32_FATSIZE	: con 36;	# 32-bit sectors per FAT
DB32_EXTFLAGS	: con 40;	# mirroring; 0 means all FATs are live
DB32_FSVERSION	: con 42;	# 0.0
DB32_ROOTCLUST	: con 44;	# root directory's first cluster
DB32_FSINFO	: con 48;	# sector number of FSInfo
DB32_BACKUP	: con 50;	# sector number of the backup boot sector
DB32_DRIVENO	: con 64;
DB32_RESERVED0	: con 65;
DB32_BOOTSIG	: con 66;
DB32_VOLID	: con 67;
DB32_LABEL	: con 71;
DB32_TYPE	: con 82;
DB32_SIZE	: con 90;

FSINFOSEC	: con 1;	# where this writes FSInfo
BACKUPSEC	: con 6;	# and the backup boot sector
#
# Written as shifts rather than as literals: limbo gives a hexadecimal
# constant with bit 31 set the type big, and int is 64 bits at runtime
# here, so "int 16rAA550000" is a sign-extended negative that compares
# equal to nothing one would expect.  A shifted int stays an int.
#
FSI_LEADSIG	: con 16r41615252;
FSI_STRUCTSIG	: con 16r61417272;
FSI_TRAILSIG	: con 16rAA55<<16;
FSI_UNKNOWN	: con (16rFFFF<<16)|16rFFFF;	# free count / next free: not maintained

FAT32MASK	: con 16r0FFFFFFF;	# the top four bits are reserved
FAT32TOP	: con 16rF<<28;		# and this is them
FAT32EOF	: con 16r0FFFFFFF;
MINFAT32	: con 65525;	# a volume with this many clusters IS FAT32
ROOTCLUST	: con 2;

# offsets in DOS directory
DD_NAME	: con 0;
DD_EXT		: con 8;
DD_ATTR		: con 11;
DD_RESERVED 	: con 12;
DD_TIME		: con 22;
DD_DATE		: con 24;
DD_START	: con 26;
DD_LENGTH	: con 28;

DD_NAMESIZE	: con 8;
DD_EXTSIZE	: con 3;
DD_SIZE		: con 32;

DRONLY	: con 16r01;
DHIDDEN	: con 16r02;
DSYSTEM	: con byte 16r04;
DVLABEL	: con byte 16r08;
DDIR	: con byte 16r10;
DARCH	: con byte 16r20;

#  the boot program for the boot sector.
bootprog := array[512] of {
16r000 =>
	byte 16rEB, byte 16r3C, byte 16r90, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00,
	byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00,
16r03E =>
	byte 16rFA, byte 16rFC, byte 16r8C, byte 16rC8, byte 16r8E, byte 16rD8, byte 16r8E, byte 16rD0,
	byte 16rBC, byte 16r00, byte 16r7C, byte 16rBE, byte 16r77, byte 16r7C, byte 16rE8, byte 16r19,
	byte 16r00, byte 16r33, byte 16rC0, byte 16rCD, byte 16r16, byte 16rBB, byte 16r40, byte 16r00,
	byte 16r8E, byte 16rC3, byte 16rBB, byte 16r72, byte 16r00, byte 16rB8, byte 16r34, byte 16r12,
	byte 16r26, byte 16r89, byte 16r07, byte 16rEA, byte 16r00, byte 16r00, byte 16rFF, byte 16rFF,
	byte 16rEB, byte 16rD6, byte 16rAC, byte 16r0A, byte 16rC0, byte 16r74, byte 16r09, byte 16rB4,
	byte 16r0E, byte 16rBB, byte 16r07, byte 16r00, byte 16rCD, byte 16r10, byte 16rEB, byte 16rF2,
	byte 16rC3,  byte 'N',  byte 'o',  byte 't',  byte ' ',  byte 'a',  byte ' ',  byte 'b',
	byte 'o',  byte 'o',  byte 't',  byte 'a',  byte 'b',  byte 'l',  byte 'e',  byte ' ',
	byte 'd',  byte 'i',  byte 's',  byte 'c',  byte ' ',  byte 'o',  byte 'r',  byte ' ',
	byte 'd',  byte 'i',  byte 's',  byte 'c',  byte ' ',  byte 'e',  byte 'r',  byte 'r',
	byte 'o',  byte 'r', byte '\r', byte '\n',  byte 'P',  byte 'r',  byte 'e',  byte 's',
	byte 's',  byte ' ',  byte 'a',  byte 'l',  byte 'm',  byte 'o',  byte 's',  byte 't',
	byte ' ',  byte 'a',  byte 'n',  byte 'y',  byte ' ',  byte 'k',  byte 'e',  byte 'y',
	byte ' ',  byte 't',  byte 'o',  byte ' ',  byte 'r',  byte 'e',  byte 'b',  byte 'o',
	byte 'o',  byte 't',  byte '.',  byte '.',  byte '.', byte 16r00, byte 16r00, byte 16r00,
16r1F0 =>
	byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00,
	byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r55, byte 16rAA,
* =>
	byte 16r00,
};

dev: string;
clustersize := 0;
fat: array of byte;	# the fat
fatbits: int;
fatsecs: int;
fatlast: int;	# last cluster allocated
clusters: int;
volsecs: int;
root: array of byte;	# first block of root
rootsecs: int;
rootfiles: int;
rootnext: int;
chatty := 0;
xflag := 0;
nresrv := 1;
dos := 0;
fflag := 0;
file: string;	# output file name
pbs: string;
typ: string;

Sof: con 1;	# start of file
Eof: con 2;	# end of file

stdin, stdout, stderr: ref Sys->FD;

fatal(str: string)
{
	sys->fprint(stderr, "format: %s\n", str);
	if(fflag && file != nil)
		sys->remove(file);
	raise "fail:error";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	daytime = load Daytime Daytime->PATH;
	disks = load Disks Disks->PATH;
	arg := load Arg Arg->PATH;
	stdin = sys->fildes(0);
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	disks->init();

	fflag = 0;
	typ = nil;
	clustersize = 0;
	writepbs := 0;
	label := array[DB_LABELSIZE] of {* => byte ' '};
	label[0:] = array of byte "CYLINDRICAL";
	arg->init(args);
	arg->setusage("disk/format [-df] [-b bootblock] [-c csize] [-l label] [-r nresrv] [-t type] disk [files ...]");
	while((o := arg->opt()) != 0)
		case o {
		'b' =>
			pbs = arg->earg();
			writepbs = 1;
		'd' =>
			dos = 1;
			writepbs = 1;
		'c' =>
			clustersize = int arg->earg();
		'f' =>
			fflag = 1;
		'l' =>
			a := array of byte arg->earg();
			if(len a > len label)
				a = a[0:len label];
			label[0:] = a;
			for(i := len a; i < len label; i++)
				label[i] = byte ' ';
		'r' =>
			nresrv = int arg->earg();
		't' =>
			typ = arg->earg();
		'v' =>
			chatty = 1;
		'x' =>
			xflag = 1;
		* =>
			arg->usage();
	}
	args = arg->argv();
	if(args == nil)
		arg->usage();
	arg = nil;

	dev = hd args;
	disk := Disk.open(dev, Sys->ORDWR, 0);
	if(disk == nil){
		if(fflag){
			fd := sys->create(dev, Sys->ORDWR, 8r666);
			if(fd != nil){
				fd = nil;
				disk = Disk.open(dev, Sys->ORDWR, 0);
			}
		}
		if(disk == nil)
			fatal(sys->sprint("opendisk %q: %r", dev));
	}

	if(disk.dtype == "file")
		fflag = 1;

	if(typ == nil){
		case disk.dtype {
		"file" =>
			typ = "3½HD";
		"floppy" =>
			sys->seek(disk.ctlfd, big 0, 0);
			buf := array[10] of byte;
			n := sys->read(disk.ctlfd, buf, len buf);
			if(n <= 0 || n >= 10)
				fatal("reading floppy type");
			typ = string buf[0:n];
		"sd" =>
			typ = "hard";
		* =>
			typ = "unknown";
		}
	}

	if(!fflag && disk.dtype == "floppy")
		if(sys->fprint(disk.ctlfd, "format %s", typ) < 0)
			fatal(sys->sprint("formatting floppy as %s: %r", typ));

	if(disk.dtype != "floppy" && !xflag)
		sanitycheck(disk);

	# check that everything will succeed
	dosfs(dos, writepbs, disk, label, tl args, 0);

	# commit
	dosfs(dos, writepbs, disk, label, tl args, 1);

	sys->print("used %bd bytes\n", big fatlast*big clustersize*big disk.secsize);
	exit;
}

#
# look for a partition table on sector 1, as would be the
# case if we were erroneously formatting 9fat without -r 2.
# if it's there and nresrv is not big enough, complain and exit.
# i've blown away my partition table too many times.
#
sanitycheck(disk: ref Disk)
{
	buf := array[512] of byte;
	bad := 0;
	if(dos && nresrv < 2 && sys->seek(disk.fd, big disk.secsize, 0) == big disk.secsize &&
	    sys->read(disk.fd, buf, len buf) >= 5 && string buf[0:5] == "part "){
		sys->fprint(sys->fildes(2), "there's a plan9 partition on the disk\n"+
			"and you didn't specify -r 2 (or greater).\n" +
			"either specify -r 2 or -x to disable this check.\n");
		bad = 1;
	}

	if(disk.dtype == "sd" && disk.offset == big 0){
		sys->fprint(sys->fildes(2), "you're attempting to format your disk (/dev/sdXX/data)\n"+
			"rather than a partition such as /dev/sdXX/9fat;\n" +
			"this is probably a mistake.  specify -x to disable this check.\n");
		bad = 1;
	}

	if(bad)
		raise "fail:failed disk sanity check";
}

#
# return the BIOS driver number for the disk.
# 16r80 is the first fixed disk, 16r81 the next, etc.
# We map sdC0=16r80, sdC1=16r81, sdD0=16r82, sdD1=16r83
#
getdriveno(disk: ref Disk): int
{
	if(disk.dtype != "sd")
		return 16r80;	# first hard disk

	name := sys->fd2path(disk.fd);
	if(len name < 3)
		return 16r80;

	#
	# The name is of the format #SsdC0/foo 
	# or /dev/sdC0/foo.
	# So that we can just look for /sdC0, turn 
	# #SsdC0/foo into #/sdC0/foo.
	#
	if(name[0:1] == "#S")
		name[1] = '/';

	for(p := name; len p >= 4; p = p[1:])
		if(p[0:2] == "sd" && (p[2]=='C' || p[2]=='D') && (p[3]=='0' || p[3]=='1'))
			return 16r80 + (p[2]-'c')*2 + (p[3]-'0');

	return 16r80;
}

writen(fd: ref Sys->FD, buf: array of byte, n: int): int
{
	# write 8k at a time, to be nice to the disk subsystem
	m: int;
	for(tot:=0; tot<n; tot+=m){
		m = n - tot;
		if(m > 8192)
			m = 8192;
		if(sys->write(fd, buf[tot:], m) != m)
			break;
	}
	return tot;
}

dosfs(dofat: int, dopbs: int, disk: ref Disk, label: array of byte, arg: list of string, commit: int)
{
	if(dofat == 0 && dopbs == 0)
		return;

	for(i := 0; i < len floppytype; i++)
		if(typ == floppytype[i].name)
			break;
	if(i == len floppytype)
		fatal(sys->sprint("unknown floppy type %q", typ));

	t := floppytype[i];
	if(t.sectors == 0 && typ == "hard"){
		t.sectors = disk.s;
		t.heads = disk.h;
		t.tracks = disk.c;
	}

	if(t.sectors == 0 && dofat)
		fatal(sys->sprint("cannot format fat with type %s: geometry unknown", typ));

	if(fflag){
		disk.size = big (t.bytes*t.sectors*t.heads*t.tracks);
		disk.secsize = t.bytes;
		disk.secs = disk.size / big disk.secsize;
	}

	secsize := disk.secsize;
	length := disk.size;

	#
	# make disk full size if a file
	#
	if(fflag && disk.dtype == "file"){
		(ok, d) := sys->fstat(disk.wfd);
		if(ok < 0)
			fatal(sys->sprint("fstat disk: %r"));
		if(commit && d.length < disk.size){
			if(sys->seek(disk.wfd, disk.size-big 1, 0) < big 0)
				fatal(sys->sprint("seek to 9: %r"));
			if(sys->write(disk.wfd, array[] of {0 => byte '9'}, 1) < 0)
				fatal(sys->sprint("writing 9: @%bd %r", sys->seek(disk.wfd, big 0, 1)));
		}
	}

	buf := array[secsize] of byte;

	#
	# start with initial sector from disk
	#
	if(sys->seek(disk.fd, big 0, 0) < big 0)
		fatal(sys->sprint("seek to boot sector: %r"));
	if(commit && sys->read(disk.fd, buf, secsize) != secsize)
		fatal(sys->sprint("reading boot sector: %r"));

	if(dofat)
		memset(buf, 0, DB32_SIZE);	# covers DB_SIZE too

	#
	# Jump instruction and OEM name
	#
	b := buf;	# hmm.
	b[DB_MAGIC+0] = byte 16rEB;
	b[DB_MAGIC+1] = byte 16r3C;
	b[DB_MAGIC+2] = byte 16r90;
	memmove(b[DB_VERSION: ], array of byte "Plan9.00", DB_VERSIONSIZE);

	#
	# Add bootstrapping code; assume it starts
	# at 16r3E (the destination of the jump we just
	# wrote to b[DB_MAGIC]
	#
	if(dopbs){
		pbsbuf := array[secsize] of byte;
		npbs: int;
		if(pbs != nil){
			if((sysfd := sys->open(pbs, Sys->OREAD)) == nil)
				fatal(sys->sprint("open %s: %r", pbs));
			npbs = sys->read(sysfd, pbsbuf, len pbsbuf);
			if(npbs < 0)
				fatal(sys->sprint("read %s: %r", pbs));
			if(npbs > secsize-2)
				fatal("boot block too large");
		}else{
			pbsbuf[0:] = bootprog;
			npbs = len bootprog;
		}
		if(npbs <= 16r3E)
			sys->fprint(sys->fildes(2), "warning: pbs too small\n");
		else
			buf[16r3E:] = pbsbuf[16r3E:npbs];
	}

	#
	# Add FAT BIOS parameter block
	#
	if(dofat){
		if(commit){
			sys->print("Initializing FAT file system\n");
			sys->print("type %s, %d tracks, %d heads, %d sectors/track, %d bytes/sec\n",
					t.name, t.tracks, t.heads, t.sectors, secsize);
		}

 		if(clustersize == 0)
	 		clustersize = t.cluster;
		#
		# the number of fat bits depends on how much disk is left
		# over after you subtract out the space taken up by the fat tables.
		# try both.  what a crock.
		#
		#
		# Try 12 bits, then 16, then 32, and stop at the first width
		# that can address what the volume turns out to hold.  The
		# third pass is new; before it, a volume of 65527 clusters or
		# more was refused outright with "disk too big; implement
		# fat32", so this tree could read a FAT32 and never make one.
		#
		# The boundaries are the specification's and not round
		# numbers: 4085 clusters is the most a FAT12 can hold and
		# 65524 the most a FAT16 can, so a volume is FAT16 at 4085
		# and FAT32 at 65525.  The old code broke out of FAT12 at
		# 4087 and refused at 65527, both two out, which put volumes
		# of 4085, 4086, 65525 and 65526 clusters into the wrong
		# format -- and those are exactly the sizes every other
		# system treats as the next one up.
		#
		for(fatbits = 12;;){
	 		volsecs = int (length/big secsize);
			#
			# here's a crock inside a crock.  even having fixed fatbits,
			# the number of fat sectors depends on the number of clusters,
			# but of course we don't know yet.  maybe iterating will get us there.
			# or maybe it will cycle.
			#
			#
			# Size the FAT and the data area together.
			#
			# They depend on each other: a bigger FAT leaves fewer
			# sectors for clusters, and fewer clusters need a
			# smaller FAT.  This used to be iterated from an
			# initial guess of zero clusters and gave up after ten
			# rounds -- "can't decide how many clusters to use" --
			# which is what any volume needing a FAT of more than
			# a few hundred sectors does, because the iteration
			# settles into a two-cycle between adjacent values
			# rather than a fixed point.  So the width was never
			# chosen for such a volume at all.
			#
			# Growing the FAT instead converges, and in one
			# direction: each step shrinks the data area, which
			# shrinks the entry count, which can only shrink what
			# the FAT needs.  Stop when the FAT is big enough for
			# every entry the data area can ask for -- which is
			# the invariant fsck_msdos checks, and the one the old
			# arithmetic could satisfy only by accident: it sized
			# the FAT for the cluster count it had computed and
			# then left the data area holding two more.
			#
			rootdirsecs := 0;
			if(fatbits == 32){
				#
				# fat32 has no fixed root directory: it is an
				# ordinary cluster chain starting at cluster 2,
				# so it costs nothing here and the entry count
				# in the BPB is written as zero.
				#
				rootsecs = 0;
				rootfiles = 0;
			} else {
				rootsecs = volsecs/200;
				rootfiles = rootsecs * (secsize/DD_SIZE);
				if(rootfiles > 512){
					rootfiles = 512;
					rootsecs = rootfiles/(secsize/DD_SIZE);
				}
				rootdirsecs = (rootfiles*DD_SIZE + secsize-1)/secsize;
			}
			fatsecs = 0;
			for(i = 0;; i++){
				data := nresrv + 2*fatsecs + rootdirsecs;
				if(data >= volsecs)
					fatal(sys->sprint("%d sectors is too small for a filesystem", volsecs));
				fit := 2 + (volsecs - data)/clustersize;
				need := (fatbits*fit + 8*secsize - 1)/(8*secsize);
				if(need <= fatsecs)
					break;
				fatsecs = need;
				if(i > 100)
					fatal("can't decide how big the fat should be");
			}
			clusters = 2 + (volsecs - (nresrv + 2*fatsecs + rootdirsecs))/clustersize;
if(chatty) sys->print("clusters %d, fat %d sectors\n", clusters, fatsecs);

if(chatty) sys->print("try %d fatbits => %d clusters of %d\n", fatbits, clusters, clustersize);
			if(fatbits == 12 && clusters >= 4085){
				fatbits = 16;
				continue;
			}
			if(fatbits == 16 && clusters >= MINFAT32){
				#
				# FAT32 wants room in the reserved area for the
				# FSInfo sector and the backup boot sector, which
				# the 1-sector default does not give.  32 is what
				# every other formatter uses.
				#
				if(nresrv <= BACKUPSEC+1)
					nresrv = 32;
				fatbits = 32;
				continue;
			}
			break;
		}
		if(fatbits == 32 && clusters < MINFAT32)
			fatal(sys->sprint("%d clusters is too few for fat32 (needs %d); use a smaller -c",
				clusters, MINFAT32));

		putshort(b[DB_SECTSIZE: ], secsize);
		b[DB_CLUSTSIZE] = byte clustersize;
		putshort(b[DB_NRESRV: ], nresrv);
		b[DB_NFATS] = byte 2;
		putshort(b[DB_ROOTSIZE: ], rootfiles);	# zero on fat32
		if(volsecs < (1<<16))
			putshort(b[DB_VOLSIZE: ], volsecs);
		b[DB_MEDIADESC] = byte t.media;
		if(fatbits == 32)
			putshort(b[DB_FATSIZE: ], 0);	# the 16-bit field must be zero
		else
			putshort(b[DB_FATSIZE: ], fatsecs);
		putshort(b[DB_TRKSIZE: ], t.sectors);
		putshort(b[DB_NHEADS: ], t.heads);
		putlong(b[DB_NHIDDEN: ], int disk.offset);
		putlong(b[DB_BIGVOLSIZE: ], volsecs);

		#
		# Extended BIOS Parameter Block
		#
		if(t.media == 16rF8)
			dno := getdriveno(disk);
		else
			dno = 0;
if(chatty) sys->print("driveno = %ux\n", dno);
		x := int (disk.offset + big b[DB_NFATS]*big fatsecs + big nresrv);
		r := sys->aprint("FAT%d    ", fatbits);
		if(len r > DB_TYPESIZE)
			r = r[0:DB_TYPESIZE];
		if(fatbits == 32){
			#
			# The fat32 block, and then the extended block at 64
			# rather than 36.  See the offsets at the top.
			#
			putlong(b[DB32_FATSIZE: ], fatsecs);
			putshort(b[DB32_EXTFLAGS: ], 0);	# both FATs live and mirrored
			putshort(b[DB32_FSVERSION: ], 0);
			putlong(b[DB32_ROOTCLUST: ], ROOTCLUST);
			putshort(b[DB32_FSINFO: ], FSINFOSEC);
			putshort(b[DB32_BACKUP: ], BACKUPSEC);
			b[DB32_DRIVENO] = byte dno;
			b[DB32_BOOTSIG] = byte 16r29;
			putlong(b[DB32_VOLID:], x);
			b[DB32_LABEL:] = label;
			b[DB32_TYPE:] = r;
		} else {
			b[DB_DRIVENO] = byte dno;
			b[DB_BOOTSIG] = byte 16r29;
			putlong(b[DB_VOLID:], x);
			b[DB_LABEL:] = label;
			b[DB_TYPE:] = r;
		}
if(chatty) sys->print("volid = %ux\n", x);
	}

	b[secsize-2] = byte Disks->Magic0;
	b[secsize-1] = byte Disks->Magic1;

	if(commit){
		if(sys->seek(disk.wfd, big 0, 0) < big 0)
			fatal(sys->sprint("seek to boot sector: %r\n"));
		if(sys->write(disk.wfd, b, secsize) != secsize)
			fatal(sys->sprint("writing to boot sector: %r"));
		if(dofat && fatbits == 32)
			writefsinfo(disk, b, secsize);
	}

	#
	# if we were only called to write the PBS, leave now
	#
	if(dofat == 0)
		return;

	#
	#  allocate an in memory fat
	#
	if(sys->seek(disk.wfd, big (nresrv*secsize), 0) < big 0)
		fatal(sys->sprint("seek to fat: %r"));
if(chatty) sys->print("fat @%buX\n", sys->seek(disk.wfd, big 0, 1));
	fat = array[fatsecs*secsize] of {* => byte 0};
	if(fat == nil)
		fatal("out of memory");
	#
	# Entry 0 is the media descriptor with every other bit set, entry 1
	# is an end-of-chain: the same convention at all three widths, just
	# wider each time.  On fat32 the top four bits of every entry are
	# reserved and must be left zero, which is why entry 1 is 0FFFFFFF
	# and not FFFFFFFF.
	#
	fat[0] = byte t.media;
	fat[1] = byte 16rff;
	fat[2] = byte 16rff;
	if(fatbits == 16)
		fat[3] = byte 16rff;
	if(fatbits == 32){
		fat[3] = byte 16r0f;
		putlong(fat[4:], FAT32EOF);	# entry 1
		#
		# On fat32 the root directory is a cluster chain like any
		# other and it starts at cluster 2, so cluster 2 is allocated
		# here, before any file gets one, and ends its own chain.
		#
		putlong(fat[4*ROOTCLUST:], FAT32EOF);
		fatlast = ROOTCLUST;
	} else
		fatlast = 1;
	if(sys->seek(disk.wfd, big (2*fatsecs*secsize), 1) < big 0)	# 2 fats
		fatal(sys->sprint("seek to root: %r"));
if(chatty) sys->print("root @%buX\n", sys->seek(disk.wfd, big 0, 1));

	#
	#  allocate an in memory root
	#
	# On fat32 the root is one cluster in the data area rather than a
	# fixed run of sectors before it, so it is the size of a cluster and
	# the file area starts after it rather than after rootsecs.
	#
	if(fatbits == 32)
		rootsecs = clustersize;
	root = array[rootsecs*secsize] of {* => byte 0};
	if(sys->seek(disk.wfd, big (rootsecs*secsize), 1) < big 0)		# rootsecs
		fatal(sys->sprint("seek to files: %r"));
if(chatty) sys->print("files @%buX\n", sys->seek(disk.wfd, big 0, 1));

	#
	# Now positioned at the Files Area.
	# If we have any arguments, process 
	# them and write out.
	#
	for(p := 0; arg != nil; arg = tl arg){
		if(p >= rootsecs*secsize)
			fatal("too many files in root");
		#
		# Open the file and get its length.
		#
		if((sysfd := sys->open(hd arg, Sys->OREAD)) == nil)
			fatal(sys->sprint("open %s: %r", hd arg));
		(ok, d) := sys->fstat(sysfd);
		if(ok < 0)
			fatal(sys->sprint("stat %s: %r", hd arg));
		if(d.length >= big 16r7FFFFFFF)
			fatal(sys->sprint("file %s too big (%bd bytes)", hd arg, d.length));
		if(commit)
			sys->print("Adding file %s, length %bd\n", hd arg, d.length);

		x: int;
		length = d.length;
		if(length > big 0){
			#
			# Allocate a buffer to read the entire file into.
			# This must be rounded up to a cluster boundary.
			#
			# Read the file and write it out to the Files Area.
			#
			length += big (secsize*clustersize - 1);
			length /= big (secsize*clustersize);
			length *= big (secsize*clustersize);
			fbuf := array[int length] of byte;
			if((nr := sys->read(sysfd, fbuf, int d.length)) != int d.length){
				if(nr >= 0)
					sys->werrstr("short read");
				fatal(sys->sprint("read %s: %r", hd arg));
			}
			for(; nr < len fbuf; nr++)
				fbuf[nr] = byte 0;
if(chatty) sys->print("%q @%buX\n", d.name, sys->seek(disk.wfd, big 0, 1));
			if(commit && writen(disk.wfd, fbuf, len fbuf) != len fbuf)
				fatal(sys->sprint("write %s: %r", hd arg));
			fbuf = nil;

			#
			# Allocate the FAT clusters.
			# We're assuming here that where we
			# wrote the file is in sync with
			# the cluster allocation.
			# Save the starting cluster.
			#
			length /= big (secsize*clustersize);
			x = clustalloc(Sof);
			for(n := 0; n < int length-1; n++)
				clustalloc(0);
			clustalloc(Eof);
		}
		else
			x = 0;

		#
		# Add the filename to the root.
		#
sys->fprint(sys->fildes(2), "add %s at clust %ux\n", d.name, x);
		addrname(root[p:], d, hd arg, x);
		p += DD_SIZE;
	}

	#
	#  write the fats and root
	#
	if(commit){
		if(sys->seek(disk.wfd, big (nresrv*secsize), 0) < big 0)
			fatal(sys->sprint("seek to fat #1: %r"));
		if(sys->write(disk.wfd, fat, fatsecs*secsize) < 0)
			fatal(sys->sprint("writing fat #1: %r"));
		if(sys->write(disk.wfd, fat, fatsecs*secsize) < 0)
			fatal(sys->sprint("writing fat #2: %r"));
		if(sys->write(disk.wfd, root, rootsecs*secsize) < 0)
			fatal(sys->sprint("writing root: %r"));
	}
}

#
# The two sectors a fat32 has that the earlier formats do not.
#
# FSInfo is a hint and nothing more: the free-cluster count and the
# next-free cluster may both be written as "unknown", and that is what
# goes here, because this program does not maintain them afterwards and
# dossrv does not either.  A wrong count is worse than no count -- it is
# what fsck_msdos reports as "Free space in FSInfo block not correct",
# and it is a real complaint about a real filesystem, whereas "is unset"
# is a statement that nobody has claimed to know.
#
# The backup boot sector is a verbatim copy at sector 6, which is where
# the BPB says to look for it, and the FSInfo copy follows it.  A volume
# whose first sector is damaged is recoverable from these and from
# nothing else.
#
writefsinfo(disk: ref Disks->Disk, boot: array of byte, secsize: int)
{
	fsi := array[secsize] of {* => byte 0};

	putlong(fsi[0:], FSI_LEADSIG);
	putlong(fsi[484:], FSI_STRUCTSIG);
	putlong(fsi[488:], FSI_UNKNOWN);	# free count
	putlong(fsi[492:], FSI_UNKNOWN);	# next free
	putlong(fsi[508:], FSI_TRAILSIG);

	if(sys->seek(disk.wfd, big (FSINFOSEC*secsize), 0) < big 0)
		fatal(sys->sprint("seek to fsinfo: %r"));
	if(sys->write(disk.wfd, fsi, secsize) != secsize)
		fatal(sys->sprint("writing fsinfo: %r"));

	if(sys->seek(disk.wfd, big (BACKUPSEC*secsize), 0) < big 0)
		fatal(sys->sprint("seek to backup boot sector: %r"));
	if(sys->write(disk.wfd, boot, secsize) != secsize)
		fatal(sys->sprint("writing backup boot sector: %r"));
	if(sys->write(disk.wfd, fsi, secsize) != secsize)
		fatal(sys->sprint("writing backup fsinfo: %r"));
}

#
#  allocate a cluster
#
clustalloc(flag: int): int
{
	o, x: int;

	if(flag != Sof){
		if (flag == Eof)
			x = 16rffff;
		else
			x = fatlast+1;
		if(fatbits == 12){
			x &= 16rfff;
			o = (3*fatlast)/2;
			if(fatlast & 1){
				fat[o] = byte ((int fat[o] & 16r0f) | (x<<4));
				fat[o+1] = byte (x>>4);
			} else {
				fat[o] = byte x;
				fat[o+1] = byte ((int fat[o+1] & 16rf0) | ((x>>8) & 16r0F));
			}
		} else if(fatbits == 32){
			#
			# 28 bits, not 32: the top four are reserved and are
			# left as they were found.  End of chain is 0FFFFFFF,
			# not the 16rffff the other widths use -- writing that
			# would name cluster 65535, which on a fat32 large
			# enough to exist is an ordinary cluster somebody else
			# owns.
			#
			if(flag == Eof)
				x = FAT32EOF;
			o = 4*fatlast;
			v := (getlong(fat[o:]) & FAT32TOP) | (x & FAT32MASK);
			putlong(fat[o:], v);
		} else {
			o = 2*fatlast;
			fat[o] = byte x;
			fat[o+1] = byte (x>>8);
		}
	}
		
	if(flag == Eof)
		return 0;
	if(++fatlast >= clusters)
		fatal(sys->sprint("data does not fit on disk (%d %d)", fatlast, clusters));
	return fatlast;
}

putname(p: string, buf: array of byte)
{
	memset(buf[DD_NAME: ], ' ', DD_NAMESIZE+DD_EXTSIZE);
	for(i := 0; i < DD_NAMESIZE && i < len p && p[i] != '.'; i++){
		c := p[i];
		if(c >= 'a' && c <= 'z')
			c += 'A'-'a';
		buf[DD_NAME+i] = byte c;
	}
	for(i = 0; i < len p; i++)
		if(p[i] == '.'){
			p = p[i+1:];
			for(i = 0; i < DD_EXTSIZE && i < len p; i++){
				c := p[i];
				if(c >= 'a' && c <= 'z')
					c += 'A'-'a';
				buf[DD_EXT+i] = byte c;
			}
			break;
		}
}

puttime(buf: array of byte)
{
	t := daytime->local(daytime->now());
	x := (t.hour<<11) | (t.min<<5) | (t.sec>>1);
	buf[DD_TIME+0] = byte x;
	buf[DD_TIME+1] = byte (x>>8);
	x = ((t.year-80)<<9) | ((t.mon+1)<<5) | t.mday;
	buf[DD_DATE+0] = byte x;
	buf[DD_DATE+1] = byte (x>>8);
}

addrname(buf: array of byte, dir: Sys->Dir, name: string, start: int)
{
	s := name;
	for(i := len s; --i >= 0;)
		if(s[i] == '/'){
			s = s[i+1:];
			break;
		}
	putname(s, buf);
	if(s == "9load")
		buf[DD_ATTR] = byte DSYSTEM;
	else
		buf[DD_ATTR] = byte 0;
	puttime(buf);
	buf[DD_START+0] = byte start;
	buf[DD_START+1] = byte (start>>8);
	buf[DD_LENGTH+0] = byte dir.length;
	buf[DD_LENGTH+1] = byte (dir.length>>8);
	buf[DD_LENGTH+2] = byte (dir.length>>16);
	buf[DD_LENGTH+3] = byte (dir.length>>24);
}

memset(d: array of byte, v: int, n: int)
{
	for (i := 0; i < n; i++)
		d[i] = byte v;
}

memmove(d: array of byte, s: array of byte, n: int)
{
	d[0:] = s[0:n];
}

putshort(b: array of byte, v: int)
{
	b[1] = byte (v>>8);
	b[0] = byte v;
}

putlong(b: array of byte, v: int)
{
	putshort(b, v);
	putshort(b[2: ], v>>16);
}

#
# Four bytes little-endian, as an unsigned value.  int is 64 bits at
# runtime here, so this never comes back negative and a mask against it
# is written out in full rather than as ~something.
#
getlong(b: array of byte): int
{
	return int b[0] | (int b[1]<<8) | (int b[2]<<16) | (int b[3]<<24);
}
