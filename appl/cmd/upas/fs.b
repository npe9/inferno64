implement Upasfs;

#
# upas/fs - present a mailbox as a file system, the Plan 9 upas way. Each
# message becomes a numbered directory holding raw/header/body and the
# parsed From/To/Subject/Date/... header fields, so any tool can read mail
# with ls and cat. This first version reads a local Unix mbox file; the
# IMAP backend (imap4(2), for Gmail) feeds the same presentation.
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
	stat:	fn(d: self ref File): ref Sys->Dir;
};

root: ref File;
files: array of ref File;
pathgen: int;

# the header fields exposed as their own files, in display order.
FIELDS := array[] of {"from", "to", "subject", "date", "cc", "reply-to", "message-id"};

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

	mountpt := "/mail/fs/mbox";
	argv = tl argv;
	while(argv != nil && len hd argv > 0 && (hd argv)[0] == '-'){
		opt := hd argv;
		argv = tl argv;
		case opt {
		"-m" =>	if(argv == nil) usage(); mountpt = hd argv; argv = tl argv;
		* =>	usage();
		}
	}
	if(argv == nil)
		usage();
	mbox := hd argv;

	files = array[16] of ref File;
	root = files[0] = mkdir("/");
	pathgen = 1;

	data := readfile(mbox);
	if(data == nil)
		error(sys->sprint("cannot read %s", mbox));
	buildtree(data);

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
	ensuredir(mountpt);
	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL, nil) < 0)
		error(sys->sprint("mount %s: %r", mountpt));
	sys->print("upas/fs: serving %s at %s\n", mbox, mountpt);
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
			if(off >= big len f.data){
				srv.reply(ref Rmsg.Read(m.tag, nil));
				break;
			}
			end := off + big n;
			if(end > big len f.data)
				end = big len f.data;
			srv.reply(ref Rmsg.Read(m.tag, f.data[int off:int end]));
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

# ---- building the tree from an mbox ----

buildtree(data: array of byte)
{
	msgs := splitmbox(data);
	i := 0;
	for(; msgs != nil; msgs = tl msgs){
		i++;
		(env, raw) := hd msgs;
		md := mkdir(string i);
		root.enter(md);
		(hdr, body, fields) := parsemsg(raw);
		md.enter(mkleaf("raw", array of byte raw));
		md.enter(mkleaf("header", array of byte hdr));
		md.enter(mkleaf("body", array of byte body));
		if(env != "")
			md.enter(mkleaf("unixheader", array of byte env));
		for(fi := 0; fi < len FIELDS; fi++)
			md.enter(mkleaf(FIELDS[fi], array of byte hdrfield(fields, FIELDS[fi])));
	}
}

# split a Unix mbox into (envelope-From line, rfc822 message) pairs. A
# message begins at a line "From " that starts the file or follows a blank
# line.
splitmbox(data: array of byte): list of (string, string)
{
	(nil, lines) := sys->tokenize(string data, "\n");
	# tokenize drops blank lines, so re-split manually keeping them.
	s := string data;
	lines = nil;
	start := 0;
	for(i := 0; i <= len s; i++){
		if(i == len s || s[i] == '\n'){
			lines = s[start:i] :: lines;
			start = i + 1;
		}
	}
	# reverse
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
	# reverse to message order
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
	# header ends at the first blank line
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

hdrfield(fields: list of (string, string), name: string): string
{
	for(; fields != nil; fields = tl fields){
		(n, v) := hd fields;
		if(n == name)
			return v;
	}
	return "";
}

# ---- File tree (adapted from tarfs) ----

mkdir(name: string): ref File
{
	f := ref File;
	f.x = 0;			# root keeps this; enter() sets it for others
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
		t := array[pathgen + 50] of ref File;
		t[0:] = files;
		files = t;
	}
	f.x = pathgen;
	f.parent = dir;
	dir.children = f :: dir.children;
	files[pathgen++] = f;
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
			n.reply <-= (files[int n.path].stat(), nil);
		Walk =>
			f := files[int n.path];
			if((f.mode & Sys->DMDIR) == 0){
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
			if((f.mode & Sys->DMDIR) == 0){
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

usage()
{
	sys->fprint(sys->fildes(2), "usage: upas/fs [-m mountpt] mboxfile\n");
	raise "fail:usage";
}

error(s: string)
{
	sys->fprint(sys->fildes(2), "upas/fs: %s\n", s);
	raise "fail:error";
}
