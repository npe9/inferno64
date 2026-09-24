implement Styxlisten;
include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	keyring: Keyring;
include "security.m";
	auth: Auth;
include "dial.m";
	dial: Dial;
include "arg.m";
include "sh.m";

Styxlisten: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

badmodule(p: string)
{
	sys->fprint(stderr(), "styxlisten: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

verbose := 0;
timing := 0;
poolsize := 0;	# 0 = one shared server (the default)
passhostnames := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	auth = load Auth Auth->PATH;
	if (auth == nil)
		badmodule(Auth->PATH);
	dial = load Dial Dial->PATH;
	if (dial == nil)
		badmodule(Dial->PATH);
	if ((e := auth->init()) != nil)
		error("auth init failed: " + e);
	keyring = load Keyring Keyring->PATH;
	if (keyring == nil)
		badmodule(Keyring->PATH);

	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmodule(Arg->PATH);

	arg->init(argv);
	arg->setusage("styxlisten [-a alg]... [-Atsv] [-P n] [-k keyfile] address cmd [arg...]");

	algs: list of string;
	doauth := 1;
	synchronous := 0;
	trusted := 0;
	keyfile := "";

	while ((opt := arg->opt()) != 0) {
		case opt {
		'P' =>
			poolsize = int arg->earg();
			if(poolsize < 1)
				arg->usage();
		'T' =>
			timing = 1;
		'v' =>
			verbose = 1;
		'a' =>
			algs = arg->earg() :: algs;
		'f' or
		'k' =>
			keyfile = arg->earg();
			if (! (keyfile[0] == '/' || (len keyfile > 2 &&  keyfile[0:2] == "./")))
				keyfile = "/usr/" + user() + "/keyring/" + keyfile;
		'h' =>
			passhostnames = 1;
		't' =>
			trusted = 1;
		's' =>
			synchronous = 1;
		'A' =>
			doauth = 0;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	if (len argv < 2)
		arg->usage();
	arg = nil;
	if (doauth && algs == nil)
		algs = getalgs();
	addr := dial->netmkaddr(hd argv, "tcp", "styx");
	cmd := tl argv;

	authinfo: ref Keyring->Authinfo;
	if (doauth) {
		if (keyfile == nil)
			keyfile = "/usr/" + user() + "/keyring/default";
		authinfo = keyring->readauthinfo(keyfile);
		if (authinfo == nil)
			error(sys->sprint("cannot read %s: %r", keyfile));
	}

	c := dial->announce(addr);
	if (c == nil)
		error(sys->sprint("cannot announce on %s: %r", addr));
	if(!trusted){
		(ok, nil) := sys->stat("/mnt/keys");
		if(ok == 0) {
			{
				sys->unmount(nil, "/mnt/keys");	# should do for now
			} exception {
				"*" => ; # ignore it
			}
		}
		# become none?
	}

	#
	# -P n: a POOL of n servers, not one shared and not one each.
	#
	# Shared, every client mounts the same pipe to the same `export /',
	# so every byte any client reads crosses one styx hop that all of
	# them queue on: with a board pulling a kernel across, a new client's
	# handshake went from 0.01s to 1.23s, because its mount is a few
	# small messages stuck behind megabytes of somebody else's.
	#
	# One server per connection fixes that -- 0.03s under the same load --
	# and does not scale: they are never reclaimed, so a board dialling
	# every fifteen seconds took the emu to 139 threads with one
	# connection open, and reads that took 30s took 70s and then 214s.
	#
	# So: a fixed pool, made once at startup and handed out round robin.
	# Bounded like the shared case, concurrent like the per-connection
	# case, and nothing accumulates because nothing is ever created after
	# startup.  Four is plenty for a board and a few probes.
	#
	# It is a flag and not the default because it only means the same
	# thing for a command that serves a namespace, like `export /'.  For
	# a command holding state that clients are meant to share, several
	# copies of it is a different program.
	#
	lsync := chan[1] of int;
	pool: array of ref Sys->FD;
	if(poolsize <= 1)
		pool = array[1] of {popen(ctxt, cmd, lsync)};
	else {
		pool = array[poolsize] of ref Sys->FD;
		for(i := 0; i < poolsize; i++){
			psync := chan[1] of int;
			pool[i] = popen(ctxt, cmd, psync);
		}
	}
	if(synchronous)
		listener(c, pool, authinfo, algs, lsync);
	else
		spawn listener(c, pool, authinfo, algs, lsync);
}

listener(c: ref Dial->Connection, pool: array of ref Sys->FD, authinfo: ref Keyring->Authinfo, algs: list of string, lsync: chan of int)
{
	next := 0;

	lsync <-= sys->pctl(0, nil);
	for (;;) {
		nc := dial->listen(c);
		if (nc == nil)
			error(sys->sprint("listen failed: %r"));
		if (verbose)
			sys->fprint(stderr(), "styxlisten: got connection from %s",
					readfile(nc.dir + "/remote"));
		dfd := dial->accept(nc);
		if (dfd == nil)
			#
			# Say so.  This was a bare "if (dfd != nil)" with no
			# else, so a failed accept dropped the connection in
			# silence: the client stayed connected, its request
			# sat unread for ever, and the server looked wedged
			# while cheerfully waiting for the next connection.
			# A whole day went into "why does the styx server
			# stop answering" for a server that was announcing a
			# failure to nobody.
			#
			sys->fprint(stderr(),
				"styxlisten: accept %s: %r\n", nc.dir);
		if (dfd != nil) {
			if(nc.cfd != nil)
				sys->fprint(nc.cfd, "keepalive");
			hostname: string;
			if(passhostnames){
				hostname = readfile(nc.dir + "/remote");
				if(hostname != nil)
					hostname = hostname[0:len hostname - 1];
			}
			cfd := pool[next];
			next = (next + 1) % len pool;
			if (algs == nil) {
				sync := chan of int;
				spawn exportproc(sync, cfd, nil, hostname, dfd);
				<-sync;
			} else
				spawn authenticator(dfd, authinfo, cfd, algs, hostname);
		}
	}
}

# authenticate a connection and set the user id.
authenticator(dfd: ref Sys->FD, authinfo: ref Keyring->Authinfo, mfd: ref Sys->FD,
		algs: list of string, hostname: string)
{
	# authenticate and change user id appropriately
	(fd, err) := auth->server(algs, authinfo, dfd, 1);
	if (fd == nil) {
		if (verbose)
			sys->fprint(stderr(), "styxlisten: authentication failed: %s\n", err);
		return;
	}
	if (verbose)
		sys->fprint(stderr(), "styxlisten: client authenticated as %s\n", err);
	sync := chan of int;
	spawn exportproc(sync, mfd, err, hostname, fd);
	<-sync;
}

exportproc(sync: chan of int, fd: ref Sys->FD, uname, hostname: string, dfd: ref Sys->FD)
{
	#
	# Where the time before a client's first reply goes.
	#
	# A client's Tversion is not read until this function reaches
	# sys->export below, and that took 28 seconds once in six
	# connections to an idle server -- with every later message on the
	# same connection answered in under a millisecond.  It looked like
	# a server that had stopped; it is a server that has not started
	# this connection yet.  -T prints the three steps so the next
	# person does not have to guess which one it is.
	#
	t0 := sys->millisec();
	sys->pctl(Sys->NEWFD | Sys->NEWNS, 2 :: fd.fd :: dfd.fd :: nil);
	t1 := sys->millisec();
	fd = sys->fildes(fd.fd);
	dfd = sys->fildes(dfd.fd);
	sync <-= 1;

	# XXX unfortunately we cannot pass through the aname from
	# the original attach, an inherent shortcoming of this scheme.
	if (sys->mount(fd, nil, "/", Sys->MREPL|Sys->MCREATE, hostname) == -1)
		error(sys->sprint("cannot mount for user '%s': %r\n", uname));
	t2 := sys->millisec();
	if(timing)
		sys->fprint(stderr(),
			"styxlisten: setup pctl %dms mount %dms (total %dms)\n",
			t1-t0, t2-t1, t2-t0);

	#
	# Look at what it returns.
	#
	# This was a bare call.  When sys->export fails it returns -1 and
	# this function simply returns, the process exits, and the client
	# is left connected to nothing: accepted, its Tversion sitting
	# unread for ever, no message anywhere.  Every connection after the
	# first failure behaves the same way, so the server looks wedged
	# while it is in fact refusing each connection in silence -- the
	# same shape of bug as the missing accept report above, twenty
	# lines away.
	#
	if(sys->export(dfd, "/", Sys->EXPWAIT) < 0)
		sys->fprint(stderr(), "styxlisten: export failed: %r\n");
}

error(e: string)
{
	sys->fprint(stderr(), "styxlisten: %s\n", e);
	raise "fail:error";
}
	

popen(ctxt: ref Draw->Context, argv: list of string, lsync: chan of int): ref Sys->FD
{
	sync := chan of int;
	fds := array[2] of ref Sys->FD;
	sys->pipe(fds);
	spawn runcmd(ctxt, argv, fds[0], sync, lsync);
	<-sync;
	return fds[1];
}

runcmd(ctxt: ref Draw->Context, argv: list of string, stdin: ref Sys->FD,
		sync: chan of int, lsync: chan of int)
{
	sys->pctl(Sys->FORKFD, nil);
	sys->dup(stdin.fd, 0);
	stdin = nil;
	sync <-= 0;
	sh := load Sh Sh->PATH;
	e := sh->run(ctxt, argv);
	kill(<-lsync, "kill");		# kill listener, as command has exited
	if(verbose){
		if(e != nil)
			sys->fprint(stderr(), "styxlisten: command exited with error: %s\n", e);
		else
			sys->fprint(stderr(), "styxlisten: command exited\n");
	}
}

kill(pid: int, how: string)
{
	sys->fprint(sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE), "%s", how);
}

user(): string
{
	if ((s := readfile("/dev/user")) == nil)
		return "none";
	return s;
}

readfile(f: string): string
{
	fd := sys->open(f, sys->OREAD);
	if(fd == nil)
		return nil;

	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;

	return string buf[0:n];	
}

getalgs(): list of string
{
	sslctl := readfile("#D/clone");
	if (sslctl == nil) {
		sslctl = readfile("#D/ssl/clone");
		if (sslctl == nil)
			return nil;
		sslctl = "#D/ssl/" + sslctl;
	} else
		sslctl = "#D/" + sslctl;
	(nil, algs) := sys->tokenize(readfile(sslctl + "/encalgs") + " " + readfile(sslctl + "/hashalgs"), " \t\n");
	return "none" :: algs;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}
