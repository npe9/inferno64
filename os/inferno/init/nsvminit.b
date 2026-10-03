implement Init;
#
# Phase 12 of doc/genesize-plan.ms: a machine assembled from a namespace
# of resources.  The machine is a directory -- kernel, initrd, mem, and
# disk/, net/, pci/ with an entry for each device -- put together with
# bind and mount before it starts, and vmlinux -N builds it from what
# is there: the kernel's virtio backends open each device by its path
# in this namespace, so whatever is bound there is what the guest gets.
#
# Here the disk is a file on another machine: the bench's Mac exports a
# directory over Styx (scripts/check-nsvm.sh runs emu for it, on the
# port plan9.ini's nsvmport names), this host mounts it at /mnt, and
# /mnt/disk.img is bound in as disk/0.  The network is the bench's
# virtio NIC, its ether(3) directory bound in as net/0.  The guest
# reads the marker the Mac wrote at the start of the disk, writes the
# next sector, which the check reads back from the file on the Mac, and
# asks for a DHCP lease on its network.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf: import dhcpclient;

Init: module
{
	init:	fn();
};

M: con "/tmp/m";	# the machine

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#H", "/dev", Sys->MAFTER);
	sys->bind("#c", "/dev", Sys->MAFTER);
	sys->bind("#I", "/net", Sys->MAFTER);
	for(i := 0; i < 3; i++)
		sys->bind(sys->sprint("#l%d", i), "/net", Sys->MAFTER);
	sys->print("NSVM: start\n");

	port := trim(readall("#e/nsvmport"));	# plan9.ini's, in the kernel's environment
	if(port == nil){
		sys->print("NSVM: FAIL no nsvmport in plan9.ini\n");
		return;
	}
	if(!dhcp())
		return;
	# no sh -c here: a shell called from this thread ends it, with
	# Limbo's exit, when its command is done
	cs := load Command "/dis/ndb/cs.dis";
	if(cs == nil){
		sys->print("NSVM: FAIL cs: %r\n");
		return;
	}
	cs->init(nil, "cs" :: nil);
	sys->print("NSVM: cs\n");
	# the Mac's directory; retried, as the listener may be late
	addr := "tcp!10.0.2.2!" + port;
	mounted := 0;
	for(i = 0; i < 10 && !mounted; i++){
		(ok, c) := sys->dial(addr, nil);
		sys->print("NSVM: dial %s: %d\n", addr, ok);
		if(ok < 0){
			sys->print("NSVM: dial %s: %r\n", addr);
			sys->sleep(3000);
			continue;
		}
		if(sys->mount(c.dfd, nil, "/mnt", Sys->MREPL, nil) < 0){
			sys->print("NSVM: mount %s: %r\n", addr);
			sys->sleep(3000);
			continue;
		}
		mounted = 1;
	}
	if(mounted)
		sys->print("NSVM: mount of %s made\n", addr);
	else
		sys->print("NSVM: mount of %s failed\n", addr);
	if(!exists("/mnt/disk.img")){
		sys->print("NSVM: FAIL /mnt/disk.img: %r\n");
		return;
	}
	sys->print("NSVM: mounted the Mac's directory\n");

	# the machine, in a memfs: names to bind resources onto
	memfs := load Command "/dis/memfs.dis";
	if(memfs == nil){
		sys->print("NSVM: FAIL memfs: %r\n");
		return;
	}
	memfs->init(nil, "memfs" :: "/tmp" :: nil);
	if(!mkdir(M) || !mkdir(M + "/disk") || !mkdir(M + "/net"))
		return;
	if(!bindfile("/guest/vmlinuz", M + "/kernel")
	|| !bindfile("/guest/initramfs.cpio", M + "/initrd")
	|| !bindfile("/mnt/disk.img", M + "/disk/0")
	|| !writefile(M + "/mem", "256\n"))
		return;
	if(exists("/net/ether1/clone")){
		if(!mkdir(M + "/net/0"))
			return;
		if(sys->bind("/net/ether1", M + "/net/0", Sys->MREPL) < 0){
			sys->print("NSVM: FAIL bind /net/ether1: %r\n");
			return;
		}
	}
	sys->print("NSVM: the machine's namespace\n");
	for(l := M :: M + "/disk" :: M + "/net" :: nil; l != nil; l = tl l)
		lsdir(hd l);
	sys->print("NSVM: building the machine\n");

	vmlinux := load Command "/dis/vmlinux.dis";
	if(vmlinux == nil){
		sys->print("NSVM: FAIL vmlinux: %r\n");
		return;
	}
	{
		vmlinux->init(nil, "vmlinux" :: "-N" :: M :: "-s" :: "1200" :: "-q" :: "LINUXGUEST: ran" :: "-d" :: "20"
			:: "-t" :: "echo LINUXGUEST: vda says $(dd if=/dev/vda bs=512 count=1 2>/dev/null | head -c 15)\n"
				+ "echo written-by-the-guest | dd of=/dev/vda bs=512 seek=1 conv=sync,fsync 2>/dev/null && echo LINUXGUEST: wrote vda\n"
				+ "if [ -e /sys/class/net/eth0 ]; then ip link set eth0 up; udhcpc -i eth0 -n -q -t 3 -s /bin/true 2>&1 | sed 's/^/LINUXGUEST: dhcp /'; fi\n"
				+ "echo LINUXGUEST: \"r\"an"
			:: nil);
	} exception e {
	"*" =>
		sys->print("NSVM: vmlinux: %s\n", e);
	}
	sys->print("NSVM: done\n");
	for(;;)
		sys->sleep(3600*1000);
}

dhcp(): int
{
	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("NSVM: FAIL dhcpclient: %r\n");
		return 0;
	}
	dhcpclient->init();
	ether := "/net/ether0";
	cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil || sys->fprint(cfd, "bind ether %s", ether) < 0){
		sys->print("NSVM: FAIL %s: %r\n", ether);
		return 0;
	}
	(cfg, nil, err) := dhcpclient->dhcp("/net", cfd, ether + "/addr", Bootconf.new(), nil);
	if(err != nil || cfg == nil || cfg.ip == nil){
		sys->print("NSVM: FAIL no lease: %s\n", err);
		return 0;
	}
	sys->print("NSVM: %s %s\n", ether, cfg.ip);
	return 1;
}

# bind a file onto a new name in the machine (the name made first)
bindfile(src, dst: string): int
{
	if(!writefile(dst, ""))
		return 0;
	if(sys->bind(src, dst, Sys->MREPL) < 0){
		sys->print("NSVM: FAIL bind %s %s: %r\n", src, dst);
		return 0;
	}
	return 1;
}

mkdir(path: string): int
{
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777);
	if(fd == nil){
		sys->print("NSVM: FAIL mkdir %s: %r\n", path);
		return 0;
	}
	return 1;
}

writefile(path, s: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("NSVM: FAIL create %s: %r\n", path);
		return 0;
	}
	b := array of byte s;
	if(len b > 0 && sys->write(fd, b, len b) != len b){
		sys->print("NSVM: FAIL write %s: %r\n", path);
		return 0;
	}
	return 1;
}

# what a directory of the machine holds, and where each came from
lsdir(dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			sys->print("NSVM: %s/%s\t%bd bytes, owner %s, device %c%d\n",
				dir, d[i].name, d[i].length, d[i].uid, d[i].dtype, d[i].dev);
	}
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

trim(s: string): string
{
	while(s != nil && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == 0))
		s = s[0:len s - 1];
	return s;
}
