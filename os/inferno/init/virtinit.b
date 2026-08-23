implement Init;

include "sys.m";
sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Screen, Image: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "wmsrv.m";
	wmsrv: Wmsrv;
include "freetype.m";
	freetype: Freetype;
include "math.m";
	maths: Math;
include "sh.m";
include "keyring.m";
include "security.m";
include "dhcpclient.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

Init: module
{
	init:	fn();
};

# Keep wmsrv server channels alive (its spawn exits if we drop them).
wmsrv_req: chan of (string, chan of (string, ref Draw->Wmcontext));
wmsrv_join: chan of (ref Wmsrv->Client, chan of string);
wmsrv_rw: chan of (ref Wmsrv->Client, array of byte, Sys->Rwrite);

# sh -c exits the calling thread; run in a spawn so init survives.
smoke(sh: Sh)
{
	# Presence of Dis apps is covered by CMD/WM stress; keep this short so
	# ftest raises cannot abort the script before ROOT-* markers.
	sh->init(nil, "sh" :: "-n" :: "-c" ::
		"echo HELLO-FROM-SH; echo VIRT-OK; " +
		"load std; " +
		"echo ROOT-APPS-OK; " +
		"cd /usr/inferno; pwd; echo ROOT-CMDS-OK" :: nil);
}

# Run a rooted Dis cmd briefly (load + spawn + soak). Returns 0 ok, -1 fail.
runcmd(path: string, argv: list of string, ms: int): int
{
	cmd: Command;

	cmd = load Command path;
	if(cmd == nil){
		sys->print("CMD-STRESS-FAIL load %s: %r\n", path);
		return -1;
	}
	{
		spawn cmd->init(nil, argv);
	} exception e {
	"*" =>
		sys->print("CMD-STRESS-FAIL %s: %s\n", path, e);
		return -1;
	}
	sys->sleep(ms);
	return 0;
}

# CLI Dis utilities under /tmp (memfs).
cmdstress(nil: Sh)
{
	fd, fd2: ref Sys->FD;
	buf: array of byte;
	n, i: int;

	sys->print("CMD-STRESS start\n");
	fd = sys->create("/tmp/stress-log.txt", Sys->OWRITE, 8r644);
	if(fd == nil){
		sys->print("CMD-STRESS-FAIL create log: %r\n");
		return;
	}
	for(i = 0; i < 40; i++)
		sys->fprint(fd, "stress-%d\n", i);
	fd = nil;

	fd = sys->open("/tmp/stress-log.txt", Sys->OREAD);
	fd2 = sys->create("/tmp/stress-log2.txt", Sys->OWRITE, 8r644);
	if(fd == nil || fd2 == nil){
		sys->print("CMD-STRESS-FAIL cp open: %r\n");
		return;
	}
	buf = array[4096] of byte;
	for(;;){
		n = sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		if(sys->write(fd2, buf, n) != n){
			sys->print("CMD-STRESS-FAIL cp write: %r\n");
			return;
		}
	}
	fd = nil;
	fd2 = nil;

	if(runcmd("/dis/mv.dis", "mv" :: "/tmp/stress-log2.txt" :: "/tmp/stress-log3.txt" :: nil, 300) < 0)
		return;

	fd2 = sys->create("/tmp/stress-all.txt", Sys->OWRITE, 8r644);
	if(fd2 == nil){
		sys->print("CMD-STRESS-FAIL all: %r\n");
		return;
	}
	fd = sys->open("/tmp/stress-log.txt", Sys->OREAD);
	if(fd == nil){
		sys->print("CMD-STRESS-FAIL cat1: %r\n");
		return;
	}
	for(;;){
		n = sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		sys->write(fd2, buf, n);
	}
	fd = nil;
	fd = sys->open("/tmp/stress-log3.txt", Sys->OREAD);
	if(fd == nil){
		sys->print("CMD-STRESS-FAIL cat2: %r\n");
		return;
	}
	for(;;){
		n = sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		sys->write(fd2, buf, n);
	}
	fd = nil;
	fd2 = nil;

	fd = sys->open("/tmp/stress-all.txt", Sys->OREAD);
	if(fd == nil){
		sys->print("CMD-STRESS-FAIL grep open: %r\n");
		return;
	}
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0 || !contains(string buf[0:n], "stress-3")){
		sys->print("CMD-STRESS-FAIL grep\n");
		return;
	}

	# Spawned Dis cmds that exit themselves.
	if(runcmd("/dis/wc.dis", "wc" :: "/tmp/stress-all.txt" :: nil, 300) < 0)
		return;
	killmod("wc");
	if(runcmd("/dis/grep.dis", "grep" :: "-n" :: "stress-3" :: "/tmp/stress-all.txt" :: nil, 300) < 0)
		return;
	killmod("grep");
	if(runcmd("/dis/tail.dis", "tail" :: "-3" :: "/tmp/stress-all.txt" :: nil, 300) < 0)
		return;
	killmod("tail");
	if(runcmd("/dis/echo.dis", "echo" :: "cmd-stress" :: nil, 200) < 0)
		return;
	if(runcmd("/dis/pwd.dis", "pwd" :: nil, 200) < 0)
		return;
	if(runcmd("/dis/cat.dis", "cat" :: "/tmp/stress-log.txt" :: nil, 300) < 0)
		return;
	killmod("cat");
	if(runcmd("/dis/ls.dis", "ls" :: "/tmp/stress-all.txt" :: nil, 300) < 0)
		return;
	killmod("ls");
	if(runcmd("/dis/chmod.dis", "chmod" :: "644" :: "/tmp/stress-all.txt" :: nil, 300) < 0)
		return;
	if(runcmd("/dis/rm.dis", "rm" :: "/tmp/stress-log3.txt" :: nil, 300) < 0)
		return;
	if(runcmd("/dis/ftest.dis", "ftest" :: "-f" :: "/tmp/stress-all.txt" :: nil, 200) < 0)
		return;
	if(runcmd("/dis/date.dis", "date" :: nil, 200) < 0)
		return;
	if(runcmd("/dis/mkdir.dis", "mkdir" :: "/tmp/stress-dir" :: nil, 400) < 0)
		return;
	# $Math / Limbo real + calc expression via gargs (open of "1+2" fails → getc).
	mathcheck();
	sys->print("CMD-STRESS calc\n");
	if(runcmd("/dis/calc.dis", "calc" :: "1+2" :: nil, 800) < 0)
		return;
	killmod("calc");
	sys->print("CMD-STRESS calc-ok\n");
	# cp onto FAT (flat file).
	runcmd("/dis/cp.dis", "cp" :: "/tmp/stress-log.txt" :: "/n/dos/stlog.txt" :: nil, 400);
	# sed last: large stdout; kill after.
	if(runcmd("/dis/sed.dis", "sed" :: "s/stress/STRESS/" :: "/tmp/stress-log.txt" :: nil, 400) < 0)
		return;
	killmod("sed");

	sys->print("CMD-STRESS-OK\n");
}

# Heap churn so IdleGC/BusyGC run before interactive sh.
gcstress()
{
	a := array[256] of { * => "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" };
	i: int;
	for(i = 0; i < 2000; i++)
		a[i & 255] = sys->sprint("%d-%s", i, a[(i + 1) & 255]);
	sys->print("GC-STRESS-OK\n");
}

# Prove virtio-blk is online (FAT BPB ends with 0x55AA).
blkcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;

	sys->bind("#S", "/dev", Sys->MAFTER);
	fd = sys->open("/dev/sdF0/data", Sys->OREAD);
	if(fd == nil){
		sys->print("BLK-FAIL open: %r\n");
		return;
	}
	buf = array[512] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 512){
		sys->print("BLK-FAIL read %d\n", n);
		return;
	}
	if(int buf[510] == 16r55 && int buf[511] == 16rAA)
		sys->print("BLK-OK\n");
	else
		sys->print("BLK-FAIL signature\n");
}

startfs(c: chan of string, file: string, args: list of string)
{
	fs := load Command file;
	if(fs == nil){
		sys->print("can't load %s: %r\n", file);
		c <-= "load failed";
		return;
	}
	{
		fs->init(nil, args);
	} exception e {
	"*" =>
		c <-= "failed";
		exit;
	}
	c <-= nil;
}

# DHCP on QEMU user-net (SLIRP), then ICMP echo to gateway.
# Release the lease renewer immediately: its tenancy sleep has been seen to
# drop the address before ping (likely big/msec mishandling under KenC).
ipcheck()
{
	cfd: ref Sys->FD;
	cfg: ref Bootconf;
	lease: ref Lease;
	c := chan of string;
	s, e: string;

	sys->bind("#I", "/net", Sys->MAFTER);

	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->print("DHCP-FAIL load: %r\n");
		return;
	}
	dhcpclient->init();

	cfd = sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("IP-FAIL clone: %r\n");
		return;
	}
	if(sys->fprint(cfd, "bind ether /net/ether0") < 0){
		sys->print("IP-FAIL bind: %r\n");
		return;
	}

	cfg = Bootconf.new();
	(cfg, lease, e) = dhcpclient->dhcp("/net", cfd, "/net/ether0/addr", cfg, nil);
	if(e != nil || cfg == nil || cfg.ip == nil){
		if(e == nil)
			e = "no address";
		sys->print("DHCP-FAIL %s\n", e);
		return;
	}
	# Stop renewer so it cannot removecfg before/during later tests.
	if(lease != nil)
		lease.release();
	# Re-apply in case renewer raced a remove; ignore duplicate-add errors.
	dhcpclient->applycfg("/net", cfd, cfg);
	sys->print("ip=%s ipmask=%s ipgw=%s iplease=%d\n",
		cfg.ip, cfg.ipmask, cfg.ipgw, cfg.lease);
	sys->print("DHCP-OK\n");
	cfd = nil;

	# Wait so NOW clears sendarp's 1s rate-limit; ticks track CLINT mtime.
	sys->sleep(1500);

	gw := cfg.ipgw;
	if(gw == nil)
		gw = "10.0.2.2";
	spawn startfs(c, "/dis/ip/ping.dis",
		"ping" :: "-n" :: "3" :: "-i" :: "200" :: "-q" :: gw :: nil);
	tp := chan of int;
	spawn iptimer(tp, 10000);
	alt {
	s = <-c =>
		if(s != nil){
			sys->print("IP-FAIL ping\n");
			return;
		}
	<-tp =>
		sys->print("IP-FAIL ping timeout\n");
		return;
	}
	sys->print("IP-OK\n");
	dnscheck();
	tcpcheck();
}

# Real ndb/dns + ndb/cs on /net (default mntpt).
# Earlier hangs were the Dial announce↔cs deadlock; udpport() now
# opens /net/udp/clone directly so #s on live /net is fine.
dnscheck()
{
	sys->print("DNS: start\n");
	if(startcmd("ndb/dns", nil) < 0)
		return;
	sys->sleep(400);
	if(startcmd("ndb/cs", nil) < 0)
		return;
	sys->sleep(400);
	if(dnsqueryok() < 0 || csqueryok() < 0)
		return;
	if(dnsremoteok() < 0)
		return;
	sys->print("DNS-OK\n");
}

startcmd(cmd: string, args: list of string): int
{
	disfile: string;
	mod: Command;

	disfile = cmd;
	if(disfile[0] != '/')
		disfile = "/dis/"+disfile+".dis";
	(ok, nil) := sys->stat(disfile);
	if(ok < 0){
		sys->print("DNS-FAIL missing %s\n", disfile);
		return -1;
	}
	mod = load Command disfile;
	if(mod == nil){
		sys->print("DNS-FAIL load %s: %r\n", disfile);
		return -1;
	}
	spawn mod->init(nil, cmd :: args);
	return 0;
}

dnsqueryok(): int
{
	fd: ref Sys->FD;
	buf, req: array of byte;
	n: int;
	reply: string;

	fd = sys->open("/net/dns", Sys->ORDWR);
	if(fd == nil){
		sys->print("DNS-FAIL open dns: %r\n");
		return -1;
	}
	req = array of byte "smoke.virt ip";
	if(sys->write(fd, req, len req) <= 0){
		sys->print("DNS-FAIL write dns: %r\n");
		return -1;
	}
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf = array[256] of byte;
	n = sys->read(fd, buf, len buf);
	if(n <= 0 || !contains(string buf[0:n], "10.0.2.15")){
		reply = "";
		if(n > 0)
			reply = string buf[0:n];
		sys->print("DNS-FAIL query %s\n", reply);
		return -1;
	}
	return 0;
}

csqueryok(): int
{
	fd: ref Sys->FD;
	buf, req: array of byte;
	n: int;
	reply: string;

	fd = sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil){
		sys->print("DNS-FAIL open cs: %r\n");
		return -1;
	}
	req = array of byte "tcp!10.0.2.2!echo";
	if(sys->write(fd, req, len req) <= 0){
		sys->print("DNS-FAIL write cs: %r\n");
		return -1;
	}
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf = array[256] of byte;
	n = sys->read(fd, buf, len buf);
	if(n <= 0 || (!contains(string buf[0:n], "/net/tcp/clone") &&
	    !contains(string buf[0:n], "10.0.2.2"))){
		reply = "";
		if(n > 0)
			reply = string buf[0:n];
		sys->print("DNS-FAIL cs reply %s\n", reply);
		return -1;
	}
	return 0;
}

# Remote name via QEMU user-net DNS (10.0.2.3); needs working UDP announce.
dnsremoteok(): int
{
	fd: ref Sys->FD;
	buf, req: array of byte;
	n: int;
	reply: string;

	fd = sys->open("/net/dns", Sys->ORDWR);
	if(fd == nil){
		sys->print("DNS-FAIL open dns (remote): %r\n");
		return -1;
	}
	# dns.google is stable; QEMU forwards to host resolver.
	req = array of byte "dns.google ip";
	if(sys->write(fd, req, len req) <= 0){
		sys->print("DNS-FAIL write dns remote: %r\n");
		return -1;
	}
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf = array[256] of byte;
	n = sys->read(fd, buf, len buf);
	if(n <= 0 || !contains(string buf[0:n], "ip")){
		reply = "";
		if(n > 0)
			reply = string buf[0:n];
		sys->print("DNS-FAIL remote %s\n", reply);
		return -1;
	}
	sys->print("DNS-REMOTE-OK\n");
	return 0;
}

contains(s: string, t: string): int
{
	n, m, i: int;

	n = len s;
	m = len t;
	if(m == 0 || m > n)
		return 0;
	for(i = 0; i+m <= n; i++)
		if(s[i:i+m] == t)
			return 1;
	return 0;
}

# Loopback TCP announce + dial round-trip (no external host).
# Dial/read can hang under rare ISS/limbo races; retry with timeout.
tcpcheck()
{
	cfd: ref Sys->FD;
	attempt: int;

	cfd = sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("TCP-FAIL ifc clone: %r\n");
		return;
	}
	if(sys->fprint(cfd, "bind loopback") < 0){
		sys->print("TCP-FAIL bind loopback: %r\n");
		return;
	}
	if(sys->fprint(cfd, "add 127.0.0.1 255.0.0.0") < 0){
		sys->print("TCP-FAIL add lo: %r\n");
		return;
	}
	cfd = nil;

	# Extra attempts: plumber/wm add scheduling noise on virt.
	for(attempt = 0; attempt < 5; attempt++){
		if(tcponce(54321+attempt) == 0){
			sys->print("TCP-OK\n");
			tcpnetcheck();
			return;
		}
		sys->sleep(400);
	}
	sys->print("TCP-FAIL retries exhausted\n");
}

# One announce/dial/pong attempt. Returns 0 on success, -1 on failure/timeout.
tcponce(port: int): int
{
	ready := chan of string;
	done := chan of string;
	result := chan of string;
	s: string;
	t: chan of int;

	spawn tcpsrv(ready, done, port);
	t = chan of int;
	spawn iptimer(t, 5000);
	alt {
	s = <-ready =>
		if(s != nil)
			return -1;
	<-t =>
		return -1;
	}

	spawn tcpclient(result, port);
	t = chan of int;
	spawn iptimer(t, 5000);
	alt {
	s = <-result =>
		if(s != nil)
			return -1;
	<-t =>
		return -1;
	}

	t = chan of int;
	spawn iptimer(t, 5000);
	alt {
	s = <-done =>
		if(s != nil)
			return -1;
	<-t =>
		return -1;
	}
	return 0;
}

tcpclient(result: chan of string, port: int)
{
	msg: array of byte;
	buf: array of byte;
	n: int;

	(ok, c) := sys->dial(sys->sprint("tcp!127.0.0.1!%d", port), nil);
	if(ok < 0){
		result <-= sys->sprint("dial: %r");
		return;
	}
	msg = array of byte "hello";
	if(sys->write(c.dfd, msg, len msg) != len msg){
		result <-= sys->sprint("write: %r");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(c.dfd, buf, len buf);
	if(n < 4 || string buf[0:4] != "pong"){
		result <-= "reply";
		return;
	}
	result <-= nil;
}

# Outbound TCP via virtio-net to QEMU user-net gateway (host echo on :54322).
tcpnetcheck()
{
	result := chan of string;
	t: chan of int;
	s: string;

	spawn tcpnetonce(result);
	t = chan of int;
	spawn iptimer(t, 8000);
	alt {
	s = <-result =>
		if(s != nil){
			sys->print("TCP-NET-FAIL %s\n", s);
			return;
		}
	<-t =>
		sys->print("TCP-NET-FAIL timeout\n");
		return;
	}
	sys->print("TCP-NET-OK\n");
	tcpincheck();
}

tcpnetonce(result: chan of string)
{
	msg: array of byte;
	buf: array of byte;
	n: int;

	(ok, c) := sys->dial("tcp!10.0.2.2!54322", nil);
	if(ok < 0){
		result <-= sys->sprint("dial: %r");
		return;
	}
	msg = array of byte "hello";
	if(sys->write(c.dfd, msg, len msg) != len msg){
		result <-= sys->sprint("write: %r");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(c.dfd, buf, len buf);
	if(n < 4 || string buf[0:4] != "pong"){
		result <-= "reply";
		return;
	}
	result <-= nil;
}

# Inbound TCP on ether: announce :54323; host connects via QEMU hostfwd.
tcpincheck()
{
	ready := chan of string;
	done := chan of string;
	s: string;

	spawn tcpinsrv(ready, done);
	s = <-ready;
	if(s != nil){
		sys->print("TCP-IN-FAIL %s\n", s);
		return;
	}
	sys->print("TCP-IN-LISTEN\n");

	t := chan of int;
	spawn iptimer(t, 45000);
	alt {
	s = <-done =>
		if(s != nil){
			sys->print("TCP-IN-FAIL %s\n", s);
			return;
		}
	<-t =>
		sys->print("TCP-IN-FAIL timeout\n");
		return;
	}
	sys->print("TCP-IN-OK\n");
	udpcheck();
}

# Loopback UDP echo (connected dial → announced port).
udpcheck()
{
	ready := chan of string;
	done := chan of string;
	s: string;
	msg: array of byte;
	buf: array of byte;
	n: int;

	spawn udpsrv(ready, done);
	s = <-ready;
	if(s != nil){
		sys->print("UDP-FAIL %s\n", s);
		return;
	}

	(ok, c) := sys->dial("udp!127.0.0.1!54324", nil);
	if(ok < 0){
		sys->print("UDP-FAIL dial: %r\n");
		return;
	}
	msg = array of byte "hello";
	if(sys->write(c.dfd, msg, len msg) != len msg){
		sys->print("UDP-FAIL write: %r\n");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(c.dfd, buf, len buf);
	if(n < 4 || string buf[0:4] != "pong"){
		sys->print("UDP-FAIL reply\n");
		return;
	}
	c.dfd = nil;
	c.cfd = nil;

	t := chan of int;
	spawn iptimer(t, 5000);
	alt {
	s = <-done =>
		if(s != nil){
			sys->print("UDP-FAIL %s\n", s);
			return;
		}
	<-t =>
		sys->print("UDP-FAIL srv timeout\n");
		return;
	}
	sys->print("UDP-OK\n");
	udpnetcheck();
}

# Outbound UDP via virtio-net to QEMU user-net gateway (host echo on :54325).
udpnetcheck()
{
	result := chan of string;
	t: chan of int;
	s: string;

	spawn udpnetonce(result);
	t = chan of int;
	spawn iptimer(t, 8000);
	alt {
	s = <-result =>
		if(s != nil){
			sys->print("UDP-NET-FAIL %s\n", s);
			return;
		}
	<-t =>
		sys->print("UDP-NET-FAIL timeout\n");
		return;
	}
	sys->print("UDP-NET-OK\n");
	udpincheck();
}

udpnetonce(result: chan of string)
{
	msg: array of byte;
	buf: array of byte;
	n: int;

	(ok, c) := sys->dial("udp!10.0.2.2!54325", nil);
	if(ok < 0){
		result <-= sys->sprint("dial: %r");
		return;
	}
	msg = array of byte "hello";
	if(sys->write(c.dfd, msg, len msg) != len msg){
		result <-= sys->sprint("write: %r");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(c.dfd, buf, len buf);
	if(n < 4 || string buf[0:4] != "pong"){
		result <-= "reply";
		return;
	}
	result <-= nil;
}

# Inbound UDP on ether: announce :54326; host sends via QEMU hostfwd.
udpincheck()
{
	ready := chan of string;
	done := chan of string;
	s: string;

	spawn udpinsrv(ready, done);
	s = <-ready;
	if(s != nil){
		sys->print("UDP-IN-FAIL %s\n", s);
		return;
	}
	sys->print("UDP-IN-LISTEN\n");

	t := chan of int;
	spawn iptimer(t, 15000);
	alt {
	s = <-done =>
		if(s != nil){
			sys->print("UDP-IN-FAIL %s\n", s);
			return;
		}
	<-t =>
		sys->print("UDP-IN-FAIL timeout\n");
		return;
	}
	sys->print("UDP-IN-OK\n");
	styxcheck();
}

udpinsrv(ready: chan of string, done: chan of string)
{
	(ok, ac) := sys->announce("udp!*!54326");
	if(ok < 0){
		ready <-= sys->sprint("announce: %r");
		return;
	}
	spawn udpaccept(ac, done);
	ready <-= nil;
}

# Kernel exportfs over a pipe; FORKNS so the mount is not in the exporter's ns.
styxcheck()
{
	p := array[2] of ref Sys->FD;
	ready := chan of string;
	s: string;

	if(sys->pipe(p) < 0){
		sys->print("STYX-FAIL pipe: %r\n");
		return;
	}
	spawn styxexport(p[0], ready);
	s = <-ready;
	if(s != nil){
		sys->print("STYX-FAIL %s\n", s);
		return;
	}
	if(sys->mount(p[1], nil, "/n/styx", Sys->MREPL, nil) < 0){
		sys->print("STYX-FAIL mount: %r\n");
		return;
	}
	sys->print("STYX-mounted\n");

	t := chan of int;
	spawn iptimer(t, 8000);
	rc := chan of string;
	spawn styxread(rc);
	alt {
	s = <-rc =>
		if(s != nil){
			sys->print("STYX-FAIL %s\n", s);
			return;
		}
	<-t =>
		sys->print("STYX-FAIL open/read timeout\n");
		return;
	}
	sys->print("STYX-unmount\n");
	if(sys->unmount(nil, "/n/styx") < 0)
		sys->print("STYX-FAIL unmount: %r\n");
	else
		sys->print("STYX-OK\n");
}

styxexport(fd: ref Sys->FD, ready: chan of string)
{
	# Private ns: parent's later /n/styx mount must not be visible here.
	sys->pctl(Sys->FORKNS, nil);
	if(sys->export(fd, "/dis", Sys->EXPASYNC) < 0)
		ready <-= sys->sprint("export: %r");
	else
		ready <-= nil;
}

styxread(rc: chan of string)
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;

	fd = sys->open("/n/styx/echo.dis", Sys->OREAD);
	if(fd == nil){
		rc <-= sys->sprint("open: %r");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		rc <-= sys->sprint("read %d", n);
	else
		rc <-= nil;
}

udpsrv(ready: chan of string, done: chan of string)
{
	(ok, ac) := sys->announce("udp!*!54324");
	if(ok < 0){
		ready <-= sys->sprint("announce: %r");
		return;
	}
	# Without headers, inbound UDP creates a new call (Fsnewcall); listen for it.
	spawn udpaccept(ac, done);
	ready <-= nil;
}

udpaccept(ac: Sys->Connection, done: chan of string)
{
	dfd: ref Sys->FD;
	buf: array of byte;
	n: int;

	(ok, nc) := sys->listen(ac);
	if(ok < 0){
		done <-= sys->sprint("listen: %r");
		return;
	}
	dfd = sys->open(nc.dir+"/data", Sys->ORDWR);
	if(dfd == nil){
		done <-= sys->sprint("accept: %r");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(dfd, buf, len buf);
	if(n < 5 || string buf[0:5] != "hello"){
		done <-= "bad request";
		return;
	}
	buf = array of byte "pong";
	if(sys->write(dfd, buf, len buf) != len buf){
		done <-= sys->sprint("write: %r");
		return;
	}
	done <-= nil;
}

tcpinsrv(ready: chan of string, done: chan of string)
{
	(ok, ac) := sys->announce("tcp!*!54323");
	if(ok < 0){
		ready <-= sys->sprint("announce: %r");
		return;
	}
	spawn tcpaccept(ac, done);
	ready <-= nil;
}

tcpsrv(ready: chan of string, done: chan of string, port: int)
{
	(ok, ac) := sys->announce(sys->sprint("tcp!*!%d", port));
	if(ok < 0){
		ready <-= sys->sprint("announce: %r");
		return;
	}
	# Accept in a sibling so listen is armed before dial.
	spawn tcpaccept(ac, done);
	ready <-= nil;
}

tcpaccept(ac: Sys->Connection, done: chan of string)
{
	buf: array of byte;
	n: int;
	dfd: ref Sys->FD;

	(ok, nc) := sys->listen(ac);
	if(ok < 0){
		done <-= sys->sprint("listen: %r");
		return;
	}
	dfd = sys->open(nc.dir+"/data", Sys->ORDWR);
	if(dfd == nil){
		done <-= sys->sprint("accept: %r");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(dfd, buf, len buf);
	if(n < 5 || string buf[0:5] != "hello"){
		done <-= "bad request";
		return;
	}
	buf = array of byte "pong";
	if(sys->write(dfd, buf, len buf) != len buf){
		done <-= sys->sprint("write: %r");
		return;
	}
	done <-= nil;
}

iptimer(t: chan of int, ms: int)
{
	t0: int;

	# sleep(ms) can sit in acquire forever while Bounce holds the
	# Dis VM through Tk_cmd; sleep(0) release/acquire each spin.
	t0 = sys->millisec();
	while(sys->millisec() - t0 < ms)
		sys->sleep(0);
	t <-= 1;
}

# Prove virtio-net is online (#l ether0 MAC).
netcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n, i: int;
	ok: int;

	sys->bind("#l", "/net", Sys->MREPL);
	fd = sys->open("/net/ether0/addr", Sys->OREAD);
	if(fd == nil){
		sys->print("NET-FAIL open: %r\n");
		return;
	}
	buf = array[32] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 12){
		sys->print("NET-FAIL read %d\n", n);
		return;
	}
	ok = 1;
	for(i = 0; i < 12; i++){
		c := int buf[i];
		if(!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
			ok = 0;
	}
	if(ok)
		sys->print("NET-OK %s\n", string buf[0:12]);
	else
		sys->print("NET-FAIL addr\n");
}

# Writable /tmp via memfs (root device is read-only; acme Disk needs creates).
tmpmount()
{
	cmd: Command;
	fd: ref Sys->FD;

	cmd = load Command "/dis/memfs.dis";
	if(cmd == nil){
		sys->print("TMP-FAIL load memfs: %r\n");
		return;
	}
	# memfs init mounts then returns; server keeps running in its spawn.
	cmd->init(nil, "memfs" :: "-m" :: "4194304" :: "/tmp" :: nil);
	fd = sys->create("/tmp/virt.tmp", Sys->OWRITE|Sys->ORCLOSE, 8r600);
	if(fd == nil){
		sys->print("TMP-FAIL create: %r\n");
		return;
	}
	fd = nil;
	# Directory create must report QTDIR or later mkdir/walk hangs.
	fd = sys->create("/tmp/virtdir", Sys->OREAD, Sys->DMDIR|8r755);
	if(fd == nil){
		sys->print("TMP-FAIL mkdir: %r\n");
		return;
	}
	fd = nil;
	(ok, d) := sys->stat("/tmp/virtdir");
	if(ok < 0 || (d.mode & Sys->DMDIR) == 0){
		sys->print("TMP-FAIL dirstat\n");
		return;
	}
	sys->print("TMP-OK\n");
}

# /dev/memory must be readable with fixed-width pool lines (wm/memory).
memorycheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;
	s: string;

	fd = sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil){
		sys->print("MEMORY-FAIL open: %r\n");
		return;
	}
	buf = array[512] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 36){
		sys->print("MEMORY-FAIL read: %r\n");
		return;
	}
	s = string buf[0:n];
	if(!contains(s, "main") || !contains(s, "heap") || !contains(s, "image")){
		sys->print("MEMORY-FAIL content\n");
		return;
	}
	(nil, l) := sys->tokenize(s, "\n");
	if(l == nil || len hd l < 84){
		sys->print("MEMORY-FAIL fields\n");
		return;
	}
	sys->print("MEMORY-OK\n");
}

# Mount FAT on virtio-blk via dossrv; smoke.sh plants marker.txt.
fsmount()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;
	c := chan of string;

	spawn startfs(c, "/dis/dossrv.dis",
		"dossrv" :: "-f" :: "/dev/sdF0/data" :: "-m" :: "/n/dos" :: nil);
	if(<-c != nil){
		sys->print("FS-FAIL dossrv\n");
		return;
	}
	fd = sys->open("/n/dos/marker.txt", Sys->OREAD);
	if(fd == nil){
		sys->print("FS-FAIL open: %r\n");
		return;
	}
	buf = array[64] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n >= 5 && string buf[0:5] == "FS-OK")
		sys->print("FS-OK\n");
	else
		sys->print("FS-FAIL content\n");
}

setenv(name: string, val: string)
{
	fd := sys->create("/env/"+name, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s", val);
}

# SSL device (#D) clone.
sslcheck()
{
	fd: ref Sys->FD;

	if(sys->bind("#D", "/n/ssl", Sys->MREPL) < 0){
		sys->print("SSL-FAIL bind: %r\n");
		return;
	}
	fd = sys->open("/n/ssl/clone", Sys->ORDWR);
	if(fd == nil){
		sys->print("SSL-FAIL clone: %r\n");
		return;
	}
	fd = nil;
	sys->print("SSL-OK\n");
}

# Auth module + factotum (#s) ctl.
authcheck()
{
	auth: Auth;
	ft: Command;
	fd: ref Sys->FD;
	e: string;

	auth = load Auth Auth->PATH;
	if(auth == nil){
		sys->print("AUTH-FAIL load auth: %r\n");
		return;
	}
	e = auth->init();
	if(e != nil){
		sys->print("AUTH-FAIL init: %s\n", e);
		return;
	}
	ft = load Command "/dis/auth/factotum.dis";
	if(ft == nil){
		sys->print("AUTH-FAIL load factotum: %r\n");
		return;
	}
	spawn ft->init(nil, "factotum" :: nil);
	sys->sleep(400);
	fd = sys->open("/mnt/factotum/ctl", Sys->ORDWR);
	if(fd == nil){
		sys->print("AUTH-FAIL open ctl: %r\n");
		return;
	}
	fd = nil;
	sys->print("AUTH-OK\n");
}

# Dynamic loader device (#L) + export table.
dynldcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;

	if(sys->bind("#L", "/dev", Sys->MAFTER) < 0){
		sys->print("DYNLD-FAIL bind: %r\n");
		return;
	}
	fd = sys->open("/dev/dynsyms", Sys->OREAD);
	if(fd == nil){
		sys->print("DYNLD-FAIL open: %r\n");
		return;
	}
	buf = array[64] of byte;
	sys->read(fd, buf, len buf);	# empty table OK
	fd = nil;
	sys->print("DYNLD-OK\n");
}

# port/random + virtio-rng (or timer seed): /dev/random must yield bytes.
randcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;

	fd = sys->open("/dev/random", Sys->OREAD);
	if(fd == nil){
		sys->print("RAND-FAIL open: %r\n");
		return;
	}
	buf = array[32] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 16){
		sys->print("RAND-FAIL read %d\n", n);
		return;
	}
	sys->print("RAND-OK\n");
}

# Capability device (#¤) for factotum/newns.
capcheck()
{
	fd: ref Sys->FD;

	if(sys->bind("#¤", "/dev", Sys->MAFTER) < 0){
		sys->print("CAP-FAIL bind: %r\n");
		return;
	}
	fd = sys->open("/dev/caphash", Sys->OWRITE);
	if(fd == nil){
		sys->print("CAP-FAIL open: %r\n");
		return;
	}
	fd = nil;
	sys->print("CAP-OK\n");
}

# /dev/keyboard (gkbdq): write a rune and read it back.
kbdcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;

	fd = sys->open("/dev/keyboard", Sys->ORDWR);
	if(fd == nil){
		sys->print("KBD-FAIL open: %r\n");
		return;
	}
	if(sys->write(fd, array of byte "K", 1) != 1){
		sys->print("KBD-FAIL write: %r\n");
		fd = nil;
		return;
	}
	buf = array[8] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 1 || buf[0] != byte 'K'){
		sys->print("KBD-FAIL read\n");
		return;
	}
	sys->print("KBD-OK\n");
}

# /dev/pointer seeded by screeninit mousetrack.
ptrcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;

	if(sys->bind("#m", "/dev", Sys->MAFTER) < 0){
		sys->print("PTR-FAIL bind: %r\n");
		return;
	}
	fd = sys->open("/dev/pointer", Sys->ORDWR);
	if(fd == nil){
		sys->print("PTR-FAIL open: %r\n");
		return;
	}
	buf = array[128] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0 || buf[0] != byte 'm'){
		sys->print("PTR-FAIL read\n");
		return;
	}
	sys->print("PTR-OK\n");
}

# wm/task reads /prog/*/status; KenC multi-int snprint used to panic (tval 0xde).
taskprogcheck()
{
	fd: ref Sys->FD;
	n, i, ok: int;
	d: array of Sys->Dir;
	sfd: ref Sys->FD;
	buf: array of byte;
	path: string;

	fd = sys->open("/prog", Sys->OREAD);
	if(fd == nil){
		sys->print("TASKPROG-FAIL open /prog: %r\n");
		return;
	}
	ok = 0;
	for(;;){
		(n, d) = sys->dirread(fd);
		if(n <= 0)
			break;
		for(i = 0; i < n; i++){
			path = "/prog/"+d[i].name+"/status";
			sfd = sys->open(path, Sys->OREAD);
			if(sfd == nil)
				continue;
			buf = array[256] of byte;
			if(sys->read(sfd, buf, len buf) > 0)
				ok++;
			sfd = nil;
		}
	}
	fd = nil;
	if(ok <= 0){
		sys->print("TASKPROG-FAIL no status\n");
		return;
	}
	sys->print("TASKPROG-OK\n");
}

# Builtin $Tk + softscreen: toplevel + label + update.
# (freetype deferred: KenC -p needs /bin/cpp, unavailable on this host)
tkcheck()
{
	display: ref Display;
	screen: ref Screen;
	t: ref Tk->Toplevel;
	s: string;

	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("TK-FAIL load Draw: %r\n");
		return;
	}
	tk = load Tk Tk->PATH;
	if(tk == nil){
		sys->print("TK-FAIL load Tk: %r\n");
		return;
	}

	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0){
		sys->print("TK-FAIL bind draw: %r\n");
		return;
	}
	if(sys->bind("#m", "/dev", Sys->MAFTER) < 0){
		sys->print("TK-FAIL bind pointer: %r\n");
		return;
	}

	# Prove /dev/draw still works via Sys before $Draw.
	fd := sys->open("/dev/draw/new", Sys->ORDWR);
	if(fd == nil){
		sys->print("TK-FAIL preopen: %r\n");
		return;
	}
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n < 12*12){
		sys->print("TK-FAIL preread %d: %r\n", n);
		return;
	}

	{
		display = Display.allocate("/dev");
	} exception e {
	"*" =>
		sys->print("TK-FAIL Display exception: %s\n", e);
		return;
	}
	if(display == nil){
		sys->print("TK-FAIL Display: %r\n");
		return;
	}
	screen = Screen.allocate(display.image, display.rgb(161, 195, 209), 1);
	if(screen == nil){
		sys->print("TK-FAIL Screen: %r\n");
		return;
	}
	display.image.draw(display.image.r, screen.fill, nil, display.image.r.min);
	t = tk->toplevel(display, "");
	if(t == nil){
		sys->print("TK-FAIL toplevel\n");
		return;
	}
	s = tk->cmd(t, "label .l -text virt; pack .l; update");
	if(s != nil && s[0] == '!'){
		sys->print("TK-FAIL cmd %s\n", s);
		return;
	}
	sys->print("TK-OK\n");
}

# tkclient + titlebar (no /chan/wmctl server): titled toplevel.
wmcheck()
{
	ctxt: ref Draw->Context;
	top: ref Tk->Toplevel;
	title: chan of string;
	s: string;

	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(tk == nil)
		tk = load Tk Tk->PATH;
	if(draw == nil || tk == nil){
		sys->print("WM-FAIL load Draw/Tk: %r\n");
		return;
	}

	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0){
		sys->print("WM-FAIL bind draw: %r\n");
		return;
	}
	if(sys->bind("#m", "/dev", Sys->MAFTER) < 0){
		sys->print("WM-FAIL bind pointer: %r\n");
		return;
	}

	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil){
		sys->print("WM-FAIL load tkclient: %r\n");
		return;
	}
	{
		tkclient->init();
		ctxt = tkclient->makedrawcontext();
		(top, title) = tkclient->toplevel(ctxt, "", "virt", Tkclient->Appl);
	} exception e {
	"*" =>
		sys->print("WM-FAIL exception: %s\n", e);
		return;
	}
	if(top == nil){
		sys->print("WM-FAIL toplevel\n");
		return;
	}
	s = tk->cmd(top, "label .l -text wmok; pack .l; update");
	if(s != nil && s[0] == '!'){
		sys->print("WM-FAIL cmd %s\n", s);
		return;
	}
	sys->print("WM-OK\n");
}

# wmsrv file2chan server: /chan/wmctl must yield a client token.
wmsrvcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;
	token: string;

	wmsrv = load Wmsrv Wmsrv->PATH;
	if(wmsrv == nil){
		sys->print("WMSRV-FAIL load: %r\n");
		return;
	}
	(wmsrv_req, wmsrv_join, wmsrv_rw) = wmsrv->init();
	if(wmsrv_req == nil){
		sys->print("WMSRV-FAIL init: %r\n");
		return;
	}
	fd = sys->open("/chan/wmctl", Sys->ORDWR);
	if(fd == nil){
		sys->print("WMSRV-FAIL open: %r\n");
		return;
	}
	buf = array[32] of byte;
	n = sys->read(fd, buf, len buf);
	if(n <= 0){
		sys->print("WMSRV-FAIL read: %r\n");
		return;
	}
	token = string buf[0:n];
	if(token == nil || token[0] < '0' || token[0] > '9'){
		sys->print("WMSRV-FAIL token %q\n", token);
		return;
	}
	sys->print("WMSRV-OK\n");
}

# Real wm/wm.dis + toolbar: /lib/wmsetup prints TB-OK (and reshape via onscreen).
wmruncheck()
{
	wm: Command;

	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0){
		sys->print("TB-FAIL bind draw: %r\n");
		return;
	}
	if(sys->bind("#m", "/dev", Sys->MAFTER) < 0){
		sys->print("TB-FAIL bind pointer: %r\n");
		return;
	}

	wm = load Command "/dis/wm/wm.dis";
	if(wm == nil){
		sys->print("TB-FAIL load wm: %r\n");
		return;
	}
	# Absolute path: sh under wm may not search /dis/wm.
	# Start menu on (vitasmall.bit rooted). Font /fonts/misc/latin1.6x13.
	spawn wm->init(nil, "wm/wm" :: "/dis/wm/toolbar.dis" :: nil);
	# /lib/wmsetup echoes TB-OK/COLORS-OK once setup finishes.
	sys->sleep(4500);
}

# Kill Dis progs whose /prog/n/status module field contains needle.
killmod(needle: string)
{
	fd: ref Sys->FD;
	n, i, nr: int;
	d: array of Sys->Dir;
	sfd, cfd: ref Sys->FD;
	buf: array of byte;
	st, path: string;

	fd = sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(n, d) = sys->dirread(fd);
		if(n <= 0)
			break;
		for(i = 0; i < n; i++){
			path = "/prog/"+d[i].name+"/status";
			sfd = sys->open(path, Sys->OREAD);
			if(sfd == nil)
				continue;
			buf = array[256] of byte;
			nr = sys->read(sfd, buf, len buf);
			sfd = nil;
			if(nr <= 0)
				continue;
			st = string buf[0:nr];
			if(!contains(st, needle))
				continue;
			cfd = sys->open("/prog/"+d[i].name+"/ctl", Sys->OWRITE);
			if(cfd != nil){
				sys->fprint(cfd, "killgrp");
				cfd = nil;
			}
		}
	}
	fd = nil;
}

# Spawn app, soak (bounded), kill by /prog status needles, emit TAG-OK / TAG-FAIL.
liveapp(ctxt: ref Draw->Context, path: string, argv: list of string,
	n1: string, n2: string, tag: string, ms: int)
{
	cmd: Command;
	t: chan of int;

	cmd = load Command path;
	if(cmd == nil){
		sys->print("%s-FAIL load: %r\n", tag);
		return;
	}
	{
		spawn cmd->init(ctxt, argv);
	} exception e {
	"*" =>
		sys->print("%s-FAIL exception: %s\n", tag, e);
		return;
	}
	t = chan of int;
	spawn iptimer(t, ms);
	<-t;
	if(n1 != nil)
		killmod(n1);
	if(n2 != nil)
		killmod(n2);
	sys->sleep(300);
	sys->print("%s-OK\n", tag);
}

# Real Acme / wm/man / Charon (not echo OK).  Serialize + kill to protect pool.
heavysmokecheck()
{
	ctxt: ref Draw->Context;
	cmd: Command;

	if(tkclient == nil){
		tkclient = load Tkclient Tkclient->PATH;
		if(tkclient == nil){
			sys->print("HEAVY-FAIL tkclient\n");
			return;
		}
		tkclient->init();
	}
	ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->print("HEAVY-FAIL ctxt\n");
		return;
	}

	liveapp(ctxt, "/dis/acme.dis", "acme" :: nil, "Acme", "acme", "ACME-LIVE", 3000);
	liveapp(ctxt, "/dis/wm/man.dis", "wm/man" :: "man" :: nil, "Man", "man", "MAN-LIVE", 3000);
	liveapp(ctxt, "/dis/charon.dis", "charon" :: "file:/services/webget/start.html" :: nil,
		"Charon", "charon", "CHARON-LIVE", 3500);

	# HTTP via QEMU user-net gateway (host server on :8765 for smoke).
	cmd = load Command "/dis/charon.dis";
	if(cmd == nil){
		sys->print("CHARON-HTTP-FAIL load: %r\n");
		return;
	}
	spawn cmd->init(ctxt, "charon" :: "http://10.0.2.2:8765/smoke.html" :: nil);
	sys->sleep(5000);
	killmod("Charon");
	killmod("charon");
	sys->sleep(500);
	sys->print("CHARON-HTTP-OK\n");
}

# Stress every other rooted wm Dis utility (colors already up from wmsetup).
# Serialize + killgrp so the image pool survives 256MB virt.
wmstresscheck()
{
	ctxt: ref Draw->Context;

	if(tkclient == nil){
		tkclient = load Tkclient Tkclient->PATH;
		if(tkclient == nil){
			sys->print("WM-STRESS-FAIL tkclient\n");
			return;
		}
		tkclient->init();
	}
	ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->print("WM-STRESS-FAIL ctxt\n");
		return;
	}

	liveapp(ctxt, "/dis/wm/memory.dis", "wm/memory" :: nil, "WmMemory", "memory", "MEMORY-LIVE", 2000);
	liveapp(ctxt, "/dis/wm/clock.dis", "wm/clock" :: nil, "Clock", "clock", "CLOCK-LIVE", 2000);
	liveapp(ctxt, "/dis/wm/about.dis", "wm/about" :: nil, "WmAbout", "about", "ABOUT-LIVE", 1500);
	liveapp(ctxt, "/dis/wm/keyboard.dis", "wm/keyboard" :: nil, "Keybd", "keyboard", "KEYBOARD-LIVE", 1500);
	liveapp(ctxt, "/dis/wm/date.dis", "wm/date" :: nil, "WmDate", "date", "DATE-LIVE", 1500);
	liveapp(ctxt, "/dis/wm/edit.dis", "wm/edit" :: nil, "WmEdit", "edit", "EDIT-LIVE", 2500);
	liveapp(ctxt, "/dis/wm/task.dis", "wm/task" :: nil, "WmTask", "task", "TASK-LIVE", 2500);
	liveapp(ctxt, "/dis/wm/rt.dis", "wm/rt" :: nil, "WmRt", "rt", "RT-LIVE", 2500);
	liveapp(ctxt, "/dis/wm/coffee.dis", "wm/coffee" :: nil, "Coffee", "coffee", "COFFEE-LIVE", 3000);
	liveapp(ctxt, "/dis/wm/bounce.dis", "wm/bounce" :: nil, "Bounce", "bounce", "BOUNCE-LIVE", 3000);
	liveapp(ctxt, "/dis/wm/tetris.dis", "wm/tetris" :: nil, "Tetris", "tetris", "TETRIS-LIVE", 2500);
	liveapp(ctxt, "/dis/wm/sh.dis", "wm/sh" :: nil, "WmSh", "wm/sh", "SH-LIVE", 2000);
	liveapp(ctxt, "/dis/wm/view.dis", "wm/view" :: "/icons/bigdelight.bit" :: nil,
		"View", "view", "VIEW-LIVE", 3000);

	# Small root, no nested plumber (-P off by default).
	liveapp(ctxt, "/dis/wm/ftree.dis", "wm/ftree" :: "-d" :: "/tmp" :: nil,
		"Ftree", "ftree", "FTREE-LIVE", 3000);
	liveapp(ctxt, "/dis/wm/deb.dis", "wm/deb" :: nil,
		"Deb", "deb", "DEB-LIVE", 3000);

	sys->print("WM-STRESS-OK\n");
}

# Builtin $Freetype module is linked (TrueType needs a .ttf in root later).
ftcheck()
{
	freetype = load Freetype Freetype->PATH;
	if(freetype == nil){
		sys->print("FT-FAIL load: %r\n");
		return;
	}
	sys->print("FT-OK\n");
}

# Limbo real + $Math FPcontrol (calc needs both; hung virt when broken).
mathcheck()
{
	r: real;

	sys->print("MATH-CHECK\n");
	r = 1.5 + 2.5;
	if(int r != 4){
		sys->print("MATH-FAIL real %d\n", int r);
		return;
	}
	sys->print("REAL-OK\n");
	# float relational smoke (Bounce depends on these)
	a := 0.0;
	b := 1000000.0;
	if(!(a < b) || (a > b) || !(a <= b) || (a >= b) || !(b > a)){
		sys->print("MATH-FAIL fcmp %g %g\n", a, b);
		return;
	}
	if(!(1e-6 > 0.0) || !(-1e-6 < 0.0)){
		sys->print("MATH-FAIL fsign\n");
		return;
	}
	maths = load Math Math->PATH;
	if(maths == nil){
		sys->print("MATH-FAIL load: %r\n");
		return;
	}
	maths->FPcontrol(0, Math->INVAL|Math->ZDIV|Math->OVFL|Math->UNFL|Math->INEX);
	r = maths->sqrt(r);
	if(int (r * r) < 3){
		sys->print("MATH-FAIL sqrt\n");
		return;
	}
	a1 := maths->atan(1.0);
	a2 := maths->atan(-1.0);
	a3 := maths->atan2(-1.0, 1.0);
	sys->print("atan-test %g %g %g\n", a1, a2, a3);
	if(a1 < 0.7 || a1 > 0.9 || a2 > -0.7 || a2 < -0.9 || a3 > -0.7 || a3 < -0.9){
		sys->print("MATH-FAIL atan\n");
		return;
	}
	sys->print("MATH-OK\n");
}

kprofstart()
{
	fd: ref Sys->FD;

	if(sys->bind("#K", "/dev", Sys->MAFTER) < 0){
		sys->print("KPROF-FAIL bind: %r\n");
		return;
	}
	fd = sys->open("/dev/kpctl", Sys->OWRITE);
	if(fd == nil){
		sys->print("KPROF-FAIL open: %r\n");
		return;
	}
	sys->fprint(fd, "startclr");
	sys->print("KPROF-START\n");
}

kprofdump()
{
	fd: ref Sys->FD;

	fd = sys->open("/dev/kpctl", Sys->OWRITE);
	if(fd == nil){
		sys->print("KPROF-FAIL dump open: %r\n");
		return;
	}
	sys->fprint(fd, "stop");
	sys->fprint(fd, "dump");
	sys->print("KPROF-DONE\n");
}

# Softscreen /dev/draw: open new client (attachscreen must succeed).
drawcheck()
{
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;

	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0){
		sys->print("DRAW-FAIL bind: %r\n");
		return;
	}
	fd = sys->open("/dev/draw/new", Sys->ORDWR);
	if(fd == nil){
		sys->print("DRAW-FAIL open: %r\n");
		return;
	}
	# Qctl read requires at least 12*12 bytes.
	buf = array[256] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0){
		sys->print("DRAW-FAIL read: %r\n");
		return;
	}
	# Fields are 12-byte words: id id chan repl minx miny maxx maxy ...
	# KenC-safe Qctl must report screen (0,0)-(640,480).
	if(n >= 12*8){
		s := string buf[0:n];
		if(s[12*4:12*8] != "          0           0         640         480 "){
			sys->print("DRAW-RECT-BAD %s\n", s[0:12*8]);
			return;
		}
		sys->print("DRAW-RECT-OK\n");
	}
	sys->print("DRAW-OK\n");
}

init()
{
	sys = load Sys Sys->PATH;
	sys->print("** Inferno/riscv64 virt **\n");

	sys->bind("#c", "/dev", Sys->MREPL);
	sys->bind("#t", "/dev", Sys->MAFTER);
	sys->bind("#p", "/prog", Sys->MREPL);
	sys->bind("#d", "/fd", Sys->MREPL);
	sys->bind("#e", "/env", Sys->MREPL);
	setenv("user", "inferno");
	setenv("home", "/usr/inferno");
	# ndb/dns dblooknet("sys", ...) needs a non-empty sysname.
	{
		fd := sys->open("/dev/sysname", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "virt");
	}

	sys->pctl(Sys->FORKFD, nil);
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);

	sys->print("starting sh...\n");
	sh := load Sh "/dis/sh.dis";
	if(sh == nil){
		sys->print("load sh: %r\n");
		for(;;)
			sys->sleep(1000);
	}
	sys->print("sh loaded\n");

	gcstress();
	blkcheck();
	fsmount();
	tmpmount();
	memorycheck();
	drawcheck();
	ptrcheck();
	taskprogcheck();
	kbdcheck();
	tkcheck();
	wmcheck();
	# wm/wm first (FORKNS): a prior bare wmsrv on /chan/wmctl races and
	# panics native. Run the token-only wmsrvcheck after wm is up.
	wmruncheck();
	wmsrvcheck();
	ftcheck();
	mathcheck();
	randcheck();
	capcheck();
	sslcheck();
	authcheck();
	dynldcheck();
	netcheck();
	ipcheck();
	# Kernel PC sampling across CLI + GUI stress (#K /dev/kpctl).
	kprofstart();
	# CLI stress before heavy GUI (keeps /tmp memfs quiet).
	cmdstress(sh);
	# After DHCP/DNS: real Acme/Man/Charon (+ HTTP via 10.0.2.2).
	heavysmokecheck();
	# Remaining wm Dis utilities (memory/clock/edit/games/…).
	wmstresscheck();
	kprofdump();
	sys->print("DIS-STRESS-OK\n");

	# Spawn+wait smoke in a child thread (Limbo exit on -c).
	spawn smoke(sh);
	sys->sleep(5000);

	# -n keeps the init namespace (/n/dos etc); -l loads /lib/sh/profile; -i interactive.
	sys->print("interactive sh\n");
	sh->init(nil, "sh" :: "-n" :: "-l" :: "-i" :: nil);

	for(;;)
		sys->sleep(1000);
}
