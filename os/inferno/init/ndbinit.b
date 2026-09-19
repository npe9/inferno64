implement Init;

#
# ndbinit: prove that a machine can join and leave the system database
# while the system is running.
#
# registry(4) already has the join and leave semantics: an entry lives
# exactly as long as the file descriptor that created it.  ndb/regndb
# renders the registry as an attrdb(6) database, which is what cs(8),
# dial(2) and every ndb consumer above them read.  This init runs both,
# has ndb/register join, looks the joiner up through Attrdb exactly the
# way cs does, kills the registering process, and looks it up again.
#
# See doc/inferno-ndb.ms.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
include "attrdb.m";
	attrdb: Attrdb;
	Db, Dbentry: import attrdb;

Init: module
{
	init:	fn();
};

Command: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Regmnt:	con "/mnt/registry";
Ndbmnt:	con "/mnt/regndb";
Ndbfile:	con Ndbmnt + "/ndb";
Sysname:	con "joiner1";
Sysaddr:	con "10.42.0.7";
Netmnt:	con "/mnt/netreg";
Netname:	con "joiner2";
Netaddr:	con "10.42.0.8";
Port:	con 6699;
Csname:	con "joiner3";
Csaddr:	con "10.42.0.10";	# not .9; quirkphase's quirk1 has that one
Waitms:	con 5000;
Stepms:	con 100;

db: ref Db;

init()
{
	sys = load Sys Sys->PATH;
	sys->bind("#c", "/dev", Sys->MAFTER);	# console
	sys->bind("#d", "/fd", Sys->MREPL);	# dup
	sys->bind("#e", "/env", Sys->MREPL|Sys->MCREATE);	# environment
	sys->bind("#p", "/prog", Sys->MREPL);	# prog
	sys->bind("#s", "/chan", Sys->MREPL);	# srv
	sys->bind("#t", "/dev", Sys->MAFTER);	# uart
	sys->print("** Inferno/arm64 virt: ndb join/leave **\n");
	sys->print("NDBINIT-OK\n");

	attrdb = load Attrdb Attrdb->PATH;
	if(attrdb == nil)
		fail(sys->sprint("load %s: %r", Attrdb->PATH));
	if((e := attrdb->init()) != nil)
		fail("attrdb init: " + e);

	if(!srv("/dis/ndb/registry.dis", "registry" :: nil, Regmnt))
		return;
	sys->print("NDB-REGISTRY-MOUNTED %s\n", Regmnt);
	if(!srv("/dis/ndb/regndb.dis", "regndb" :: "-m" :: Regmnt :: nil, Ndbmnt))
		return;
	sys->print("NDB-REGNDB-MOUNTED %s\n", Ndbmnt);

	show(Ndbmnt+"/ctl", "ctl before");
	show(Ndbfile, "ndb before");

	db = Db.open(Ndbfile);
	if(db == nil)
		fail(sys->sprint("Db.open %s: %r", Ndbfile));
	if(lookup() != nil){
		sys->print("NDB-EMPTY-FAIL: %s already present\n", Sysname);
		return;
	}
	sys->print("NDB-EMPTY-OK %s absent before anyone joins\n", Sysname);

	# join: ndb/register holds the registry file descriptor open
	pidc := chan of int;
	spawn joiner(pidc);
	pid := <-pidc;
	if(pid < 0){
		sys->print("NDB-JOIN-FAIL: can't start register\n");
		return;
	}
	sys->print("NDB-JOIN pid %d registering %s\n", pid, Sysname);

	(ms, ip) := waitfor(1);
	if(ip == nil){
		sys->print("NDB-JOIN-FAIL: %s not in the database after %d ms\n", Sysname, Waitms);
		show(Ndbmnt+"/ctl", "ctl after join");
		show(Ndbfile, "ndb after join");
		return;
	}
	sys->print("NDB-JOIN-OK %s ip=%s after %d ms\n", Sysname, ip, ms);
	show(Ndbmnt+"/ctl", "ctl after join");
	show(Ndbfile, "ndb after join");
	query("sys" :: Sysname :: "ip" :: nil);

	# attrdb must not think the database has moved when it has not
	db.reopen();
	if(db.changed()){
		sys->print("NDB-CHANGED-FAIL: changed with no registry change\n");
		return;
	}
	sys->print("NDB-CHANGED-OK quiet database reports no change\n");

	# leave: kill the registering process; registry strikes the entry
	# off when its file descriptor is closed
	cfd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(cfd == nil)
		fail(sys->sprint("open /prog/%d/ctl: %r", pid));
	if(sys->fprint(cfd, "kill") < 0)
		fail(sys->sprint("kill %d: %r", pid));
	cfd = nil;
	sys->print("NDB-KILL pid %d\n", pid);

	#
	# Dbf.changed compares dev, type, Qid.path, Qid.vers and mtime.
	# regndb bumps Qid.vers on every render, which is what makes a
	# synthetic file visible to attrdb at all.
	#
	cms := waitchanged();
	if(cms < 0){
		sys->print("NDB-CHANGED-FAIL: Db.changed() never became true\n");
		return;
	}
	sys->print("NDB-CHANGED-OK Db.changed() true %d ms after the leave\n", cms);

	(ms, ip) = waitfor(0);
	if(ip != nil){
		sys->print("NDB-LEAVE-FAIL: %s still ip=%s after %d ms\n", Sysname, ip, Waitms);
		show(Ndbmnt+"/ctl", "ctl after leave");
		show(Ndbfile, "ndb after leave");
		return;
	}
	sys->print("NDB-LEAVE-OK %s gone after %d ms\n", Sysname, ms);
	show(Ndbmnt+"/ctl", "ctl after leave");
	show(Ndbfile, "ndb after leave");
	query("sys" :: Sysname :: "ip" :: nil);
	quirkphase();
	netphase();
	csphase();
	sys->print("NDB-DONE\n");
	for(;;)
		sys->sleep(10000);
}

#
# The awkward registrations: a value with a space in it, a value with a
# quote in it, and an attribute called regsvc, which is the name regndb
# gives the registry's own service name.
#
quirkphase()
{
	pidc := chan of int;
	spawn quirkjoiner(pidc);
	pid := <-pidc;
	if(pid < 0){
		sys->print("NDB-QUIRK-FAIL: can't start register\n");
		return;
	}
	(ms, nil) := waitname("quirk1", 1);
	if(lookupname("quirk1") == nil){
		sys->print("NDB-QUIRK-FAIL quirk1 absent after %d ms\n", ms);
		show(Ndbfile, "ndb after quirk join");
		return;
	}
	show(Ndbfile, "ndb after quirk join");
	show(Ndbmnt+"/ctl", "ctl after quirk join");
	desc := lookupattr("quirk1", "desc");
	if(desc != "a b c"){
		sys->print("NDB-QUOTE-FAIL desc=%q, wanted \"a b c\"\n", desc);
		return;
	}
	note := lookupattr("quirk1", "note");
	if(note != "it's"){
		sys->print("NDB-QUOTE-FAIL note=%q, wanted \"it's\"\n", note);
		return;
	}
	sys->print("NDB-QUOTE-OK desc=%q note=%q\n", desc, note);
	rs := lookupattr("quirk1", "regsvc");
	if(rs != "tcp!10.42.0.9!0"){
		sys->print("NDB-REGSVC-FAIL regsvc=%q, wanted the registry name\n", rs);
		return;
	}
	sys->print("NDB-REGSVC-OK regsvc=%q, the registration's own was dropped\n", rs);

	cfd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(cfd != nil)
		sys->fprint(cfd, "kill");
	cfd = nil;
	(ms, nil) = waitname("quirk1", 0);
	if(lookupname("quirk1") != nil){
		sys->print("NDB-QUIRK-FAIL quirk1 still present after %d ms\n", ms);
		return;
	}
	sys->print("NDB-QUIRK-OK quirk1 gone after %d ms\n", ms);
}

quirkjoiner(pidc: chan of int)
{
	sys->pctl(Sys->NEWFD, 1 :: 2 :: nil);
	m := load Command "/dis/ndb/register.dis";
	if(m == nil){
		sys->print("NDB: load register: %r\n");
		pidc <-= -1;
		return;
	}
	pidc <-= sys->pctl(0, nil);
	m->init(nil, "register" :: "-m" :: Regmnt :: "tcp!10.42.0.9!0" ::
		"sys" :: "quirk1" :: "ip" :: "10.42.0.9" ::
		"desc" :: "a b c" :: "note" :: "it's" :: "regsvc" :: "bogus" :: nil);
	sys->print("NDB: quirk register returned\n");
}

#
# The same join and leave, but over a network connection: the registry
# is exported over TCP and mounted back, a machine joins through that
# mount, and then the connection is broken the way a machine that has
# gone away breaks it.  Nobody clunks anything; exportfs tears its fids
# down when the connection dies, and the registry strikes the entry off.
#
netphase()
{
	sys->bind("#I", "/net", Sys->MAFTER);
	cfd := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(cfd == nil){
		sys->print("NDB-NET-FAIL ipifc clone: %r\n");
		return;
	}
	if(sys->fprint(cfd, "bind loopback") < 0 ||
	   sys->fprint(cfd, "add 127.0.0.1 255.0.0.0") < 0){
		sys->print("NDB-NET-FAIL loopback: %r\n");
		return;
	}
	cfd = nil;

	addr := sys->sprint("tcp!127.0.0.1!%d", Port);
	(aok, ac) := sys->announce(addr);
	if(aok < 0){
		sys->print("NDB-NET-FAIL announce %s: %r\n", addr);
		return;
	}
	epidc := chan of int;
	spawn exporter(ac, epidc);
	sys->sleep(200);
	(dok, dc) := sys->dial(addr, nil);
	if(dok < 0){
		sys->print("NDB-NET-FAIL dial %s: %r\n", addr);
		return;
	}
	if(<-epidc < 0)
		return;
	if(sys->mount(dc.dfd, nil, Netmnt, Sys->MREPL, nil) < 0){
		sys->print("NDB-NET-FAIL mount %s: %r\n", Netmnt);
		return;
	}
	sys->print("NDB-NET-MOUNTED %s over %s\n", Netmnt, addr);

	pidc := chan of int;
	spawn netjoiner(pidc);
	pid := <-pidc;
	if(pid < 0){
		sys->print("NDB-NET-FAIL: can't start register\n");
		return;
	}
	(ms, ip) := waitname(Netname, 1);
	if(ip == nil){
		sys->print("NDB-NET-JOIN-FAIL %s absent after %d ms\n", Netname, Waitms);
		show(Ndbmnt+"/ndb", "ndb after net join");
		return;
	}
	sys->print("NDB-NET-JOIN-OK %s ip=%s after %d ms\n", Netname, ip, ms);

	# break the connection under the mount, without unmounting
	if(sys->fprint(dc.cfd, "hangup") < 0){
		sys->print("NDB-NET-FAIL hangup: %r\n");
		return;
	}
	sys->print("NDB-NET-HANGUP %s\n", addr);
	(ms, ip) = waitname(Netname, 0);
	if(ip != nil){
		sys->print("NDB-NET-LEAVE-FAIL %s still ip=%s after %d ms\n", Netname, ip, Waitms);
		show(Ndbmnt+"/ndb", "ndb after hangup");
		return;
	}
	sys->print("NDB-NET-LEAVE-OK %s gone %d ms after the connection dropped\n", Netname, ms);
	show(Ndbmnt+"/ctl", "ctl after hangup");
	show(Ndbfile, "ndb after hangup");
}

exporter(ac: Sys->Connection, pidc: chan of int)
{
	(ok, c) := sys->listen(ac);
	if(ok < 0){
		sys->print("NDB-NET-FAIL listen: %r\n");
		pidc <-= -1;
		return;
	}
	dfd := sys->open(c.dir+"/data", Sys->ORDWR);
	if(dfd == nil){
		sys->print("NDB-NET-FAIL open %s/data: %r\n", c.dir);
		pidc <-= -1;
		return;
	}
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, dfd.fd :: 1 :: 2 :: nil);
	sys->export(dfd, Regmnt, Sys->EXPWAIT);
}

netjoiner(pidc: chan of int)
{
	sys->pctl(Sys->NEWFD, 1 :: 2 :: nil);
	m := load Command "/dis/ndb/register.dis";
	if(m == nil){
		sys->print("NDB: load register: %r\n");
		pidc <-= -1;
		return;
	}
	pidc <-= sys->pctl(0, nil);
	m->init(nil, "register" :: "-m" :: Netmnt :: "tcp!"+Netaddr+"!0" ::
		"sys" :: Netname :: "ip" :: Netaddr :: nil);
	sys->print("NDB: net register returned\n");
}

#
# look Sysname up the way cs(8) does: reopen the database, then find the
# entry keyed on sys and take its ip.
#
#
# cs itself, against the rendered database.  Everything above looks
# names up through Attrdb directly, which is the same library cs uses
# but not the same program; this starts the real connection server with
# -f pointing at the synthetic file and asks it to translate a name the
# way anything dialling by name would.
#
# The control is free and it is the point: after the machine leaves,
# the same query must fail.  cs re-reads its database only when the
# string "refresh" is written to /net/cs, so that write is part of the
# test rather than a workaround -- it is how a name server on this
# machine would be told the fleet had changed.
#
csphase()
{
	pidc := chan of int;

	spawn csjoiner(pidc);
	pid := <-pidc;
	if(pid < 0){
		sys->print("NDB-CS-FAIL: can't start register for %s\n", Csname);
		return;
	}
	(ms, ip) := waitname(Csname, 1);
	if(ip == nil){
		sys->print("NDB-CS-FAIL: %s not in the database after %d ms\n",
			Csname, ms);
		return;
	}

	spawn cscmd();
	for(ms = 0; ms <= Waitms; ms += Stepms){
		(ok, nil) := sys->stat("/net/cs");
		if(ok == 0)
			break;
		sys->sleep(Stepms);
	}
	(ok, nil) := sys->stat("/net/cs");
	if(ok < 0){
		sys->print("NDB-CS-FAIL: no /net/cs after %d ms\n", Waitms);
		return;
	}
	sys->print("NDB-CS-STARTED /net/cs after %d ms, -f %s\n", ms, Ndbfile);

	a := csquery("tcp!" + Csname + "!564");
	if(a == nil || !hasstr(a, Csaddr)){
		sys->print("NDB-CS-FAIL: cs answered %q for %s, wanted %s\n",
			a, Csname, Csaddr);
		return;
	}
	sys->print("NDB-CS-OK cs translated %s to %q\n", Csname, a);

	# leave, then the same question must stop having an answer
	cfd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(cfd == nil || sys->fprint(cfd, "kill") < 0){
		sys->print("NDB-CS-FAIL: can't kill %d: %r\n", pid);
		return;
	}
	cfd = nil;
	(ms, ip) = waitname(Csname, 0);
	if(ip != nil){
		sys->print("NDB-CS-FAIL: %s still ip=%s after %d ms\n",
			Csname, ip, ms);
		return;
	}
	csrefresh();
	a = csquery("tcp!" + Csname + "!564");
	if(a != nil && hasstr(a, Csaddr)){
		sys->print("NDB-CS-FAIL: cs still answers %q for a machine that left\n", a);
		return;
	}
	sys->print("NDB-CS-GONE-OK cs no longer translates %s (%q)\n",
		Csname, a);
}

csjoiner(pidc: chan of int)
{
	sys->pctl(Sys->NEWFD, 1 :: 2 :: nil);
	m := load Command "/dis/ndb/register.dis";
	if(m == nil){
		sys->print("NDB: load register: %r\n");
		pidc <-= -1;
		return;
	}
	pidc <-= sys->pctl(0, nil);
	m->init(nil, "register" :: "-m" :: Regmnt :: "tcp!"+Csaddr+"!0" ::
		"sys" :: Csname :: "ip" :: Csaddr :: nil);
	sys->print("NDB: register (cs) returned\n");
}

cscmd()
{
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	m := load Command "/dis/ndb/cs.dis";
	if(m == nil){
		sys->print("NDB-CS-FAIL: load cs: %r\n");
		return;
	}
	m->init(nil, "cs" :: "-f" :: Ndbfile :: nil);
	sys->print("NDB: cs returned\n");
}

csquery(q: string): string
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil)
		return nil;
	b := array of byte q;
	if(sys->write(fd, b, len b) != len b)
		return nil;
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

csrefresh()
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil)
		return;
	b := array of byte "refresh";
	sys->write(fd, b, len b);
}

hasstr(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

lookup(): string
{
	return lookupname(Sysname);
}

lookupname(name: string): string
{
	return lookupattr(name, "ip");
}

lookupattr(name: string, attr: string): string
{
	db.reopen();
	(e, nil) := db.findpair(nil, "sys", name);
	if(e == nil)
		return nil;
	return e.findfirst(attr);
}

waitfor(want: int): (int, string)
{
	return waitname(Sysname, want);
}

waitname(name: string, want: int): (int, string)
{
	for(ms := 0; ms <= Waitms; ms += Stepms){
		ip := lookupname(name);
		if((ip != nil) == want)
			return (ms, ip);
		sys->sleep(Stepms);
	}
	return (Waitms, lookupname(name));
}

waitchanged(): int
{
	for(ms := 0; ms <= Waitms; ms += Stepms){
		if(db.changed())
			return ms;
		sys->sleep(Stepms);
	}
	return -1;
}

#
# the same lookup through ndb/query, the command an operator would use
#
query(args: list of string)
{
	sys->print("--- ndb/query -f %s %s\n", Ndbfile, joinargs(args));
	spawn runquery("query" :: "-f" :: Ndbfile :: args);
	sys->sleep(1000);
	sys->print("--- end ndb/query\n");
}

runquery(args: list of string)
{
	m := load Command "/dis/ndb/query.dis";
	if(m == nil){
		sys->print("NDB: load query: %r\n");
		return;
	}
	m->init(nil, args);
}

joinargs(args: list of string): string
{
	s := "";
	for(; args != nil; args = tl args)
		s += hd args + " ";
	return s;
}

joiner(pidc: chan of int)
{
	sys->pctl(Sys->NEWFD, 1 :: 2 :: nil);
	m := load Command "/dis/ndb/register.dis";
	if(m == nil){
		sys->print("NDB: load register: %r\n");
		pidc <-= -1;
		return;
	}
	pidc <-= sys->pctl(0, nil);
	m->init(nil, "register" :: "-m" :: Regmnt :: "tcp!"+Sysaddr+"!0" ::
		"sys" :: Sysname :: "ip" :: Sysaddr :: "dom" :: Sysname+".test" :: nil);
	sys->print("NDB: register returned\n");
}

#
# start a file server on a pipe and mount it
#
srv(path: string, args: list of string, mnt: string): int
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->print("NDB: pipe: %r\n");
		return 0;
	}
	spawn runsrv(fds[0], path, args);
	fds[0] = nil;
	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, nil) < 0){
		sys->print("NDB: mount %s on %s: %r\n", path, mnt);
		return 0;
	}
	return 1;
}

runsrv(pfd: ref Sys->FD, path: string, args: list of string)
{
	sys->pctl(Sys->NEWFD, pfd.fd :: 1 :: 2 :: nil);
	if(pfd.fd != 0)
		sys->dup(pfd.fd, 0);
	m := load Command path;
	if(m == nil){
		sys->print("NDB: load %s: %r\n", path);
		return;
	}
	m->init(nil, args);
}

show(path: string, what: string)
{
	sys->print("--- %s (%s)\n", what, path);
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		sys->print("NDB: open %s: %r\n", path);
		return;
	}
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		sys->write(sys->fildes(1), buf, n);
	sys->print("--- end %s\n", what);
}

fail(s: string)
{
	sys->print("NDB-FAIL: %s\n", s);
	for(;;)
		sys->sleep(10000);
}
