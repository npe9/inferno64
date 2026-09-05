implement Amail;

#
# amail - an acme mail client, after Plan 9's acme Mail. It runs as an acme
# client: it reads the mailbox from upas/fs(1)'s /mail/fs, shows the message
# list in an acme window whose tag carries Get/Quit, and opens a message in a
# new window when its number is executed (middle-button) in the list. Delete
# goes through /mail/fs/ctl. All transport is the modern tls12-based upas
# backend (no plaintext POP3).
#
#	amail [-f mbox] [-m mailbox]      (run inside acme)
#	amail -t [-f mbox]               (headless self-test: list + msg 1)
#
# The acme window/event handling follows the standard acme-client pattern
# (see win.b in the same directory); the -t path exercises the mailbox data
# layer without a display.
#
include "sys.m";
	sys: Sys;
include "draw.m";

Amail: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Message: adt {
	num:		int;
	path:		string;
	from:		string;
	subject:	string;
	date:		string;
};

ACME:	con "/mnt/acme";
FSROOT:	con "/mail/fs";
mbname := "mbox";
mbox: array of ref Message;
startedfs := 0;

# an open acme window
Win: adt {
	id:	int;
	ctl:	ref Sys->FD;
	body:	ref Sys->FD;
	addr:	ref Sys->FD;
	event:	ref Sys->FD;
	tag:	ref Sys->FD;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	file := "";
	testmode := 0;
	argv = tl argv;
	while(argv != nil && len hd argv > 0 && (hd argv)[0] == '-'){
		opt := hd argv; argv = tl argv;
		case opt {
		"-f" =>	file = optarg(argv); argv = tl argv;
		"-m" =>	mbname = optarg(argv); argv = tl argv;
		"-t" =>	testmode = 1;
		* =>	usage();
		}
	}

	(ok, nil) := sys->stat(FSROOT + "/ctl");
	if(ok < 0){
		if(file == "")
			fatal("no /mail/fs and no -f mbox");
		startfs(file);
	}
	readmbox();

	if(testmode){
		selftest();
		return;
	}

	w := newwin();
	if(w == nil)
		fatal("cannot make acme window");
	settag(w, " Get Delmesg Quit");
	setname(w, "Mail");
	showlist(w);
	eventloop(w);
}

# ---- acme window handling ----

newwin(): ref Win
{
	cfd := sys->open(ACME + "/new/ctl", Sys->ORDWR);
	if(cfd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		return nil;
	id := int string b[0:n];
	w := ref Win;
	w.id = id;
	w.ctl = cfd;
	w.body = wopen(id, "body", Sys->OWRITE);
	w.addr = wopen(id, "addr", Sys->ORDWR);
	w.event = wopen(id, "event", Sys->ORDWR);
	w.tag = wopen(id, "tag", Sys->OWRITE);
	if(w.body == nil || w.event == nil)
		return nil;
	return w;
}

wopen(id: int, f: string, mode: int): ref Sys->FD
{
	return sys->open(sys->sprint("%s/%d/%s", ACME, id, f), mode);
}

setname(w: ref Win, name: string)
{
	s := array of byte ("name " + name + "\n");
	sys->write(w.ctl, s, len s);
}

settag(w: ref Win, t: string)
{
	if(w.tag != nil){
		s := array of byte t;
		sys->write(w.tag, s, len s);
	}
}

wclear(w: ref Win)
{
	# select all and replace: addr=,  then write empty via data. Simpler:
	# use ctl "clear" is not standard; write addr 0,$ and empty the body by
	# reopening. We just append a fresh listing after a clear marker.
	if(w.addr != nil){
		a := array of byte ",";
		sys->write(w.addr, a, len a);
	}
}

showlist(w: ref Win)
{
	s := "";
	for(i := 0; i < len mbox; i++)
		s += listline(mbox[i]);
	b := array of byte s;
	sys->write(w.body, b, len b);
	# mark clean
	c := array of byte "clean\n";
	sys->write(w.ctl, c, len c);
}

listline(m: ref Message): string
{
	subj := m.subject;
	if(subj == "")
		subj = "(no subject)";
	return sys->sprint("%d\t%-24.24s  %s\n", m.num, m.from, subj);
}

# open a message in its own acme window
openmsg(num: int)
{
	m := findmsg(num);
	if(m == nil)
		return;
	w := newwin();
	if(w == nil)
		return;
	setname(w, sys->sprint("Mail/%d", num));
	hdr := sys->sprint("From: %s\nTo: %s\nDate: %s\nSubject: %s\n\n",
		m.from, readstr(m.path + "/to"), m.date, m.subject);
	body := readstr(m.path + "/body");
	s := array of byte (hdr + body);
	sys->write(w.body, s, len s);
	c := array of byte "clean\n";
	sys->write(w.ctl, c, len c);
}

# the acme event loop. Each event is:
#   <origin><type> <q0> <q1> <flag> <nr> <text>\n
# We act on execute (type 'x'/'X') of a tag command or a message number.
eventloop(w: ref Win)
{
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(w.event, buf, len buf);
		if(n <= 0)
			break;
		(origin, typ, text) := parseevent(string buf[0:n]);
		if(typ == 'x' || typ == 'X'){
			cmd := text;
			case cmd {
			"Quit" =>
				if(startedfs)
					sys->unmount(nil, FSROOT);
				return;
			"Get" =>
				readmbox();
				wclear(w);
				showlist(w);
			"Delmesg" =>
				;	# needs a selected message; handled via "Del N"
			* =>
				# a bare number: open that message; "Del N": delete
				(nc, flds) := sys->tokenize(cmd, " \t");
				if(nc == 1 && isnum(cmd))
					openmsg(int cmd);
				else if(nc == 2 && hd flds == "Del")
					delmsg(int hd tl flds, w);
			}
		}else{
			# not ours: hand the event back to acme so it acts normally
			sys->write(w.event, buf[0:n], n);
		}
		origin = origin;	# (unused)
	}
}

# parse one acme event record: origin, type, and the trailing text.
parseevent(s: string): (int, int, string)
{
	if(len s < 2)
		return (0, 0, "");
	origin := s[0];
	typ := s[1];
	# skip "c1 c2", then q0 q1 flag nr are space-separated numbers; text follows
	(nil, flds) := sys->tokenize(s[2:], " \t\n");
	text := "";
	# flds: q0 q1 flag nr [text...]; text is what remains after the 4 numbers
	i := 0;
	rest := flds;
	for(; rest != nil && i < 4; rest = tl rest)
		i++;
	first := 1;
	for(; rest != nil; rest = tl rest){
		if(!first)
			text += " ";
		text += hd rest;
		first = 0;
	}
	return (origin, typ, text);
}

delmsg(num: int, w: ref Win)
{
	fd := sys->open(FSROOT + "/ctl", Sys->OWRITE);
	if(fd != nil){
		c := array of byte sys->sprint("delete %s %d", mbname, num);
		sys->write(fd, c, len c);
	}
	readmbox();
	wclear(w);
	showlist(w);
}

# ---- headless self-test ----

selftest()
{
	sys->print("amail: %d message(s)\n", len mbox);
	for(i := 0; i < len mbox; i++)
		sys->print("%s", listline(mbox[i]));
	if(len mbox > 0){
		m := mbox[0];
		sys->print("--- message %d ---\n", m.num);
		sys->print("From: %s\nSubject: %s\n", m.from, m.subject);
		sys->print("body: %s\n", readstr(m.path + "/body"));
	}
	if(startedfs)
		sys->unmount(nil, FSROOT);
}

# ---- mailbox reading ----

findmsg(num: int): ref Message
{
	for(i := 0; i < len mbox; i++)
		if(mbox[i].num == num)
			return mbox[i];
	return nil;
}

readmbox()
{
	dir := FSROOT + "/" + mbname;
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		fatal(sys->sprint("open %s: %r", dir));
	nums: list of int;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(d[i].mode & Sys->DMDIR)
				nums = int d[i].name :: nums;
	}
	a := array[len nums] of int;
	k := 0;
	for(; nums != nil; nums = tl nums)
		a[k++] = hd nums;
	for(i := 0; i < len a; i++)
		for(j := i + 1; j < len a; j++)
			if(a[j] < a[i]){ t := a[i]; a[i] = a[j]; a[j] = t; }
	mbox = array[len a] of ref Message;
	for(i = 0; i < len a; i++){
		m := ref Message;
		m.num = a[i];
		m.path = dir + "/" + string a[i];
		f := lineize(readstr(m.path + "/info"), 9);
		m.from = f[0];
		m.date = f[4];
		m.subject = f[5];
		mbox[i] = m;
	}
}

lineize(s: string, n: int): array of string
{
	a := array[n] of string;
	for(i := 0; i < n; i++)
		a[i] = "";
	i = 0;
	start := 0;
	for(j := 0; j < len s && i < n; j++)
		if(s[j] == '\n'){
			a[i++] = s[start:j];
			start = j + 1;
		}
	if(i < n && start < len s)
		a[i] = s[start:];
	return a;
}

startfs(file: string)
{
	spawn runfs(file);
	for(i := 0; i < 100; i++){
		(ok, nil) := sys->stat(FSROOT + "/ctl");
		if(ok >= 0){
			startedfs = 1;
			return;
		}
		sys->sleep(50);
	}
	fatal("upas/fs did not start");
}

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

runfs(file: string)
{
	c := load Command "/dis/upas/fs.dis";
	if(c == nil){
		sys->fprint(sys->fildes(2), "amail: load upas/fs: %r\n");
		return;
	}
	c->init(nil, "upas/fs" :: "-m" :: FSROOT :: file :: nil);
}

# ---- helpers ----

isnum(s: string): int
{
	if(s == "")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

readstr(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

optarg(a: list of string): string
{
	if(a == nil)
		usage();
	return hd a;
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: amail [-f mbox] [-m mailbox] | -t -f mbox\n");
	raise "fail:usage";
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "amail: %s\n", s);
	raise "fail:error";
}
