implement Upasfs;

#
# upas/fs - present a mailbox as a file system, the Plan 9 upas way. It
# mounts at /mail/fs and serves a `ctl' file plus a `mbox' directory; each
# message in the mailbox is a numbered directory holding the Plan 9 upas
# file set (info, raw, header, body, and the parsed From/To/Subject/...
# fields), with MIME parts as numbered sub-directories. `ctl' accepts
# `delete mbox n ...', which rewrites the backing mbox. This is the live
# interface nedmail(1) and other Plan 9 mail tools drive, not a snapshot.
#
# The backend is a local Unix mbox file, or (with -i) an IMAP mailbox
# fetched over TLS (imap4(2)); both feed the same presentation.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound: import styxservers;
include "mime.m";
	mime: Mime;
	Part: import mime;
include "keyring.m";
	kr: Keyring;
include "tls12.m";
include "imap4.m";
	imap4: Imap4;
	Client: import imap4;

Upasfs: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

File: adt {
	x:		int;
	name:		string;
	mode:		int;
	mtime:		int;
	data:		array of byte;		# leaf content (in memory)
	parent:		cyclic ref File;
	children:	cyclic list of ref File;

	find:	fn(f: self ref File, name: string): ref File;
	enter:	fn(d: self ref File, f: ref File);
	remove:	fn(d: self ref File, f: ref File);
	stat:	fn(d: self ref File): ref Sys->Dir;
};

# a message in the mailbox, kept so the mbox can be rewritten on delete.
Msg: adt {
	num:	int;
	env:	string;		# unix "From " envelope line
	raw:	string;		# the rfc822 message
	dir:	ref File;
	alive:	int;
};

root: ref File;
ctlfile: ref File;
mboxdir: ref File;
files: array of ref File;
pathgen: int;

msgs: list of ref Msg;		# in mailbox order
mboxpath := "";			# backing mbox file, "" for imap (no rewrite)

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil)
		error("load styx");
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		error("load styxservers");
	styxservers->init(styx);
	mime = load Mime Mime->PATH;
	if(mime == nil)
		error("load mime");
	mime->init();
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		error("load keyring");

	rootmnt := "/mail/fs";
	imapmode := 0;
	imapserver := "imap.gmail.com";
	dialip := "";
	port := 993;
	user := "";
	passfile := "";
	nwant := 25;
	argv = tl argv;
	while(argv != nil && len hd argv > 0 && (hd argv)[0] == '-'){
		opt := hd argv;
		argv = tl argv;
		case opt {
		"-m" =>	rootmnt = optarg(argv); argv = tl argv;
		"-i" =>	imapmode = 1;
		"-s" =>	imapserver = optarg(argv); argv = tl argv;
		"-a" =>	dialip = optarg(argv); argv = tl argv;
		"-p" =>	port = int optarg(argv); argv = tl argv;
		"-u" =>	user = optarg(argv); argv = tl argv;
		"-P" =>	passfile = optarg(argv); argv = tl argv;
		"-n" =>	nwant = int optarg(argv); argv = tl argv;
		* =>	usage();
		}
	}

	files = array[64] of ref File;
	root = files[0] = mkdir("/");
	pathgen = 1;
	# the two entries at the mailbox-server root: a control file and the
	# default mailbox directory.
	ctlfile = mkleaf("ctl", nil);
	ctlfile.mode = 8r666;
	root.enter(ctlfile);
	mboxdir = mkdir("mbox");
	root.enter(mboxdir);

	if(imapmode){
		if(user == "")
			error("-i needs -u user (and -P passfile)");
		buildmessages(fetchimap(imapserver, dialip, port, user, readpass(passfile), nwant));
	}else{
		if(argv == nil)
			usage();
		mboxpath = hd argv;
		data := readfile(mboxpath);
		if(data == nil)
			error(sys->sprint("cannot read %s", mboxpath));
		buildmessages(splitmbox(data));
	}

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		error(sys->sprint("pipe: %r"));
	navops := chan of ref Navop;
	spawn navigator(navops);
	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big 0);
	fds[0] = nil;
	pidc := chan of int;
	spawn server(tchan, srv, pidc, navops);
	<-pidc;
	ensuredir(rootmnt);
	if(sys->mount(fds[1], nil, rootmnt, Sys->MREPL, nil) < 0)
		error(sys->sprint("mount %s: %r", rootmnt));
	sys->print("upas/fs: serving at %s\n", rootmnt);
}

server(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(0, nil);
Serve:
	while((gm := <-tchan) != nil){
		pick m := gm {
		Readerror =>
			sys->fprint(sys->fildes(2), "upas/fs: read error: %s\n", m.error);
			break Serve;
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR){
				srv.default(m);		# readdir
				break;
			}
			f := files[int c.path];
			off := m.offset;
			n := m.count;
			if(f.data == nil || off >= big len f.data){
				srv.reply(ref Rmsg.Read(m.tag, nil));
				break;
			}
			end := off + big n;
			if(end > big len f.data)
				end = big len f.data;
			srv.reply(ref Rmsg.Read(m.tag, f.data[int off:int end]));
		Write =>
			(c, err) := srv.canwrite(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(int c.path == ctlfile.x){
				e := doctl(string m.data);
				if(e != nil){
					srv.reply(ref Rmsg.Error(m.tag, e));
					break;
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
				break;
			}
			srv.reply(ref Rmsg.Error(m.tag, "read-only"));
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

# ---- ctl ----

# the mailbox control file. nedmail and friends write:
#   open <path> <name>      (we serve a single mailbox, so this is a no-op)
#   close <name>            (no-op)
#   delete <name> <n> ...   (remove those messages and rewrite the mbox)
doctl(cmd: string): string
{
	(nil, tok) := sys->tokenize(cmd, " \t\r\n");
	if(tok == nil)
		return nil;
	case hd tok {
	"open" or "close" =>
		return nil;
	"delete" =>
		tok = tl tok;			# skip verb
		if(tok != nil)
			tok = tl tok;		# skip mailbox name
		for(; tok != nil; tok = tl tok)
			deletemsg(int hd tok);
		if(mboxpath != "")
			rewritembox();
		return nil;
	* =>
		return "unknown control message";
	}
}

deletemsg(num: int)
{
	for(l := msgs; l != nil; l = tl l){
		m := hd l;
		if(m.num == num && m.alive){
			m.alive = 0;
			if(m.dir != nil)
				mboxdir.remove(m.dir);
			return;
		}
	}
}

rewritembox()
{
	s := "";
	for(l := msgs; l != nil; l = tl l){
		m := hd l;
		if(!m.alive)
			continue;
		env := m.env;
		if(env == "")
			env = "From upas";
		s += env + "\n" + m.raw;
		if(len m.raw > 0 && m.raw[len m.raw - 1] != '\n')
			s += "\n";
		s += "\n";
	}
	fd := sys->create(mboxpath, Sys->OWRITE|Sys->OTRUNC, 8r600);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "upas/fs: rewrite %s: %r\n", mboxpath);
		return;
	}
	d := array of byte s;
	sys->write(fd, d, len d);
}

# ---- building the tree ----

# fetch the most recent n messages from an IMAP server (imap4(2), over
# TLS) and return them as (envelope, raw) pairs for buildmessages.
fetchimap(server, dialip: string, port: int, user, pass: string, n: int): list of (string, string)
{
	imap4 = load Imap4 Imap4->PATH;
	if(imap4 == nil)
		error("load imap4");
	if((e := imap4->init()) != nil)
		error("imap4 init: " + e);
	(c, ce) := imap4->connect(server, port, dialip);
	if(ce != nil)
		error("connect: " + ce);
	if((le := c.login(user, pass)) != nil)
		error("login: " + le);
	(cnt, se) := c.select("INBOX");
	if(se != nil)
		error("select: " + se);
	start := cnt - n + 1;
	if(start < 1)
		start = 1;
	rmsgs: list of (string, string);
	for(m := start; m <= cnt; m++){
		(data, fe) := c.fetch(m, "BODY.PEEK[]");
		if(fe != nil)
			error("fetch: " + fe);
		rmsgs = (sys->sprint("From imap message %d", m), string data) :: rmsgs;
	}
	c.logout();
	res: list of (string, string);
	for(; rmsgs != nil; rmsgs = tl rmsgs)
		res = hd rmsgs :: res;
	return res;
}

buildmessages(raw: list of (string, string))
{
	ml: list of ref Msg;
	i := 0;
	for(; raw != nil; raw = tl raw){
		i++;
		(env, r) := hd raw;
		m := ref Msg(i, env, r, nil, 1);
		m.dir = buildmsgdir(m);
		ml = m :: ml;
	}
	# msgs in mailbox order
	msgs = nil;
	for(; ml != nil; ml = tl ml)
		msgs = hd ml :: msgs;
}

buildmsgdir(m: ref Msg): ref File
{
	md := mkdir(string m.num);
	mboxdir.enter(md);
	(hdr, body, fields) := parsemsg(m.raw);
	part := mime->parse(array of byte m.raw);

	# decoded body: for multipart, the first text/plain part.
	decbody := part.body;
	if(part.ismultipart()){
		tp := part.find("text/plain");
		if(tp != nil)
			decbody = tp.body;
		else
			decbody = array of byte body;
	}

	from := fld(fields, "from");
	if(from == "" && m.env != "")
		from = envfrom(m.env);
	date := fld(fields, "date");
	if(date == "")
		date = envdate(m.env);
	replyto := fld(fields, "reply-to");
	if(replyto == "")
		replyto = from;
	disposition := "inline";
	filename := "";
	if(part.filename != ""){
		disposition = "file";
		filename = part.filename;
	}
	digest := hexsha1(array of byte m.raw);
	nlines := countlines(decbody);

	# the info file: 16 fields, one per line, in Plan 9 upas order. nedmail
	# reads the first nine (from,to,cc,replyto,date,subject,type,
	# disposition,filename); the rest complete the Plan 9 contract.
	info :=	from + "\n" +
		fld(fields, "to") + "\n" +
		fld(fields, "cc") + "\n" +
		replyto + "\n" +
		date + "\n" +
		mime->hdrdecode(fld(fields, "subject")) + "\n" +
		part.ctype + "\n" +
		disposition + "\n" +
		filename + "\n" +
		digest + "\n" +
		fld(fields, "bcc") + "\n" +
		fld(fields, "in-reply-to") + "\n" +
		date + "\n" +
		fld(fields, "sender") + "\n" +
		fld(fields, "message-id") + "\n" +
		string nlines + "\n";
	md.enter(mkleaf("info", array of byte info));

	md.enter(mkleaf("raw", array of byte m.raw));
	md.enter(mkleaf("rawunix", array of byte (m.env + "\n" + m.raw)));
	md.enter(mkleaf("header", array of byte hdr));
	md.enter(mkleaf("rawheader", array of byte hdr));
	md.enter(mkleaf("mimeheader", array of byte hdr));
	md.enter(mkleaf("body", decbody));
	md.enter(mkleaf("rawbody", array of byte body));
	if(m.env != "")
		md.enter(mkleaf("unixheader", array of byte m.env));
	md.enter(mkleaf("type", array of byte part.ctype));
	md.enter(mkleaf("disposition", array of byte disposition));
	if(filename != "")
		md.enter(mkleaf("filename", array of byte filename));
	md.enter(mkleaf("digest", array of byte digest));
	md.enter(mkleaf("lines", array of byte string nlines));

	# individual header-field files (Plan 9 names, no hyphens).
	md.enter(mkleaf("from", array of byte mime->hdrdecode(from)));
	md.enter(mkleaf("to", array of byte mime->hdrdecode(fld(fields, "to"))));
	md.enter(mkleaf("cc", array of byte mime->hdrdecode(fld(fields, "cc"))));
	md.enter(mkleaf("bcc", array of byte fld(fields, "bcc")));
	md.enter(mkleaf("replyto", array of byte replyto));
	md.enter(mkleaf("subject", array of byte mime->hdrdecode(fld(fields, "subject"))));
	md.enter(mkleaf("date", array of byte date));
	md.enter(mkleaf("sender", array of byte fld(fields, "sender")));
	md.enter(mkleaf("messageid", array of byte fld(fields, "message-id")));
	md.enter(mkleaf("inreplyto", array of byte fld(fields, "in-reply-to")));

	if(part.ismultipart())
		addparts(md, part.parts);
	return md;
}

# expose a message's MIME parts as numbered subdirectories, each with
# type/encoding/filename and the decoded body (recursing into nested
# multiparts), as Plan 9 upas/fs does.
addparts(parent: ref File, parts: list of ref Part)
{
	i := 0;
	for(; parts != nil; parts = tl parts){
		i++;
		p := hd parts;
		pd := mkdir(string i);
		parent.enter(pd);
		pd.enter(mkleaf("type", array of byte p.ctype));
		pd.enter(mkleaf("encoding", array of byte p.encoding));
		disp := "inline";
		if(p.filename != ""){
			disp = "file";
			pd.enter(mkleaf("filename", array of byte p.filename));
		}
		pd.enter(mkleaf("disposition", array of byte disp));
		if(p.ismultipart())
			addparts(pd, p.parts);
		else
			pd.enter(mkleaf("body", p.body));
	}
}

# ---- mbox and message parsing ----

# split a Unix mbox into (envelope-From line, rfc822 message) pairs. A
# message begins at a line "From " that starts the file or follows a blank
# line.
splitmbox(data: array of byte): list of (string, string)
{
	s := string data;
	lines: list of string;
	start := 0;
	for(i := 0; i <= len s; i++){
		if(i == len s || s[i] == '\n'){
			lines = s[start:i] :: lines;
			start = i + 1;
		}
	}
	ord: list of string;
	for(; lines != nil; lines = tl lines)
		ord = hd lines :: ord;

	msgs: list of (string, string);
	env := "";
	cur := "";
	prevblank := 1;
	have := 0;
	for(l := ord; l != nil; l = tl l){
		line := hd l;
		if(prevblank && isfromline(line)){
			if(have)
				msgs = (env, cur) :: msgs;
			env = line;
			cur = "";
			have = 1;
			prevblank = 0;
			continue;
		}
		if(have)
			cur += line + "\n";
		prevblank = (line == "" || line == "\r");
	}
	if(have)
		msgs = (env, cur) :: msgs;
	res: list of (string, string);
	for(; msgs != nil; msgs = tl msgs)
		res = hd msgs :: res;
	return res;
}

isfromline(line: string): int
{
	return len line >= 5 && line[0:5] == "From ";
}

# split a message into (header, body) and parse header fields (lowercased
# name -> value, continuation lines folded).
parsemsg(raw: string): (string, string, list of (string, string))
{
	hdrend := len raw;
	body := "";
	for(i := 0; i + 1 < len raw; i++){
		if(raw[i] == '\n' && (raw[i + 1] == '\n' || (raw[i + 1] == '\r' && i + 2 < len raw && raw[i + 2] == '\n'))){
			hdrend = i + 1;
			bstart := i + 2;
			if(raw[i + 1] == '\r')
				bstart = i + 3;
			body = raw[bstart:];
			break;
		}
	}
	hdr := raw[0:hdrend];
	fields := parsefields(hdr);
	return (hdr, body, fields);
}

parsefields(hdr: string): list of (string, string)
{
	(nil, lines) := sys->tokenize(hdr, "\n");
	rf: list of (string, string);
	name := "";
	val := "";
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(line != "" && (line[0] == ' ' || line[0] == '\t')){
			val += " " + strip(line);		# folded continuation
			continue;
		}
		if(name != "")
			rf = (name, val) :: rf;
		name = "";
		val = "";
		colon := indexof(line, ":");
		if(colon > 0){
			name = lower(line[0:colon]);
			val = strip(line[colon + 1:]);
		}
	}
	if(name != "")
		rf = (name, val) :: rf;
	fields: list of (string, string);
	for(; rf != nil; rf = tl rf)
		fields = hd rf :: fields;
	return fields;
}

fld(fields: list of (string, string), name: string): string
{
	for(; fields != nil; fields = tl fields){
		(n, v) := hd fields;
		if(n == name)
			return v;
	}
	return "";
}

# pull the address and date out of a unix "From addr weekday mon day time year"
# envelope line.
envfrom(env: string): string
{
	(n, t) := sys->tokenize(env, " \t");
	if(n >= 2)
		return hd tl t;
	return "";
}

envdate(env: string): string
{
	(n, t) := sys->tokenize(env, " \t");
	if(n < 3)
		return "";
	t = tl tl t;			# skip "From" and the address
	d := "";
	for(; t != nil; t = tl t){
		if(d != "")
			d += " ";
		d += hd t;
	}
	return d;
}

countlines(body: array of byte): int
{
	n := 0;
	for(i := 0; i < len body; i++)
		if(body[i] == byte '\n')
			n++;
	return n;
}

hexsha1(data: array of byte): string
{
	dig := array[Keyring->SHA1dlen] of byte;
	kr->sha1(data, len data, dig, nil);
	s := "";
	for(i := 0; i < len dig; i++)
		s += sys->sprint("%.2x", int dig[i]);
	return s;
}

# ---- File tree (adapted from tarfs) ----

mkdir(name: string): ref File
{
	f := ref File;
	f.x = 0;
	f.name = name;
	f.mode = Sys->DMDIR | 8r555;
	f.mtime = 0;
	f.data = nil;
	return f;
}

mkleaf(name: string, data: array of byte): ref File
{
	f := ref File;
	f.x = 0;
	f.name = name;
	f.mode = 8r444;
	f.mtime = 0;
	f.data = data;
	return f;
}

File.enter(dir: self ref File, f: ref File)
{
	if(pathgen >= len files){
		t := array[pathgen + 64] of ref File;
		t[0:] = files;
		files = t;
	}
	f.x = pathgen;
	f.parent = dir;
	dir.children = f :: dir.children;
	files[pathgen++] = f;
}

File.remove(dir: self ref File, f: ref File)
{
	nl: list of ref File;
	for(g := dir.children; g != nil; g = tl g)
		if(hd g != f)
			nl = hd g :: nl;
	dir.children = nl;
	if(f.x >= 0 && f.x < len files)
		files[f.x] = nil;		# unreachable by walk
}

File.find(f: self ref File, name: string): ref File
{
	for(g := f.children; g != nil; g = tl g)
		if((hd g).name == name)
			return hd g;
	return nil;
}

File.stat(f: self ref File): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.mode = f.mode;
	d.qid.path = big f.x;
	d.qid.qtype = f.mode >> 24;
	d.name = f.name;
	d.uid = "upas";
	d.gid = "upas";
	d.muid = "upas";
	if(f.data != nil)
		d.length = big len f.data;
	d.mtime = f.mtime;
	d.atime = f.mtime;
	return d;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
		pick n := m {
		Stat =>
			f := files[int n.path];
			if(f == nil)
				n.reply <-= (nil, Enotfound);
			else
				n.reply <-= (f.stat(), nil);
		Walk =>
			f := files[int n.path];
			if(f == nil || (f.mode & Sys->DMDIR) == 0){
				n.reply <-= (nil, "not a directory");
				break;
			}
			case n.name {
			".." =>
				if(f.parent != nil)
					f = f.parent;
				n.reply <-= (f.stat(), nil);
			* =>
				f = f.find(n.name);
				if(f != nil)
					n.reply <-= (f.stat(), nil);
				else
					n.reply <-= (nil, Enotfound);
			}
		Readdir =>
			f := files[int n.path];
			if(f == nil || (f.mode & Sys->DMDIR) == 0){
				n.reply <-= (nil, "not a directory");
				break;
			}
			g := f.children;
			for(i := n.offset; i > 0 && g != nil; i--)
				g = tl g;
			for(; --n.count >= 0 && g != nil; g = tl g)
				n.reply <-= ((hd g).stat(), nil);
			n.reply <-= (nil, nil);
		}
	}
}

# ---- helpers ----

lower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j - 1] == ' ' || s[j - 1] == '\t' || s[j - 1] == '\r'))
		j--;
	return s[i:j];
}

indexof(s: string, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return i;
	return -1;
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		no := array[len out + n] of byte;
		no[0:] = out;
		no[len out:] = buf[0:n];
		out = no;
	}
	return out;
}

ensuredir(path: string)
{
	(nil, elems) := sys->tokenize(path, "/");
	cur := "";
	for(; elems != nil; elems = tl elems){
		cur += "/" + hd elems;
		(ok, nil) := sys->stat(cur);
		if(ok < 0){
			fd := sys->create(cur, Sys->OREAD, Sys->DMDIR | 8r777);
			if(fd == nil)
				error(sys->sprint("create %s: %r", cur));
		}
	}
}

optarg(a: list of string): string
{
	if(a == nil)
		usage();
	return hd a;
}

readpass(passfile: string): string
{
	if(passfile == "")
		error("-i needs -P passfile");
	fd := sys->open(passfile, Sys->OREAD);
	if(fd == nil)
		error(sys->sprint("open %s: %r", passfile));
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		error("empty passfile");
	s := string buf[0:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: upas/fs [-m rootmnt] mboxfile\n");
	sys->fprint(sys->fildes(2), "       upas/fs -i -u user -P passfile [-s server] [-a dialip] [-n n] [-m rootmnt]\n");
	raise "fail:usage";
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "upas/fs: %s\n", s);
	raise "fail:error";
}
