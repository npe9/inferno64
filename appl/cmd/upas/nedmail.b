implement Nedmail;

#
# nedmail - the interactive command-line mail reader, after Plan 9's
# upas/nedmail. It is a client of upas/fs's /mail/fs namespace: it lists
# the mailbox's numbered message directories, reads each message's `info'
# and content files, and deletes through /mail/fs/ctl. If /mail/fs is not
# already served and -f names an mbox, it starts upas/fs on it.
#
# Commands (a message address may precede most of them; a bare address
# prints that message, a bare newline advances):
#   p  print message      P  raw message      "  quoted body
#   h  one-line summary    H  MIME structure   b  next 10 summaries
#   d  mark deleted        u  unmark           =  message number
#   w file  save body      s file  append raw to a file
#   y / i  resync mailbox  q  quit (flush deletes)   x  quit (no flush)
#   help
# Addresses: N (number), . (current), $ (last), ^ (first), +n, -n,
#   /regexp/ (search from/subject/to forward).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "regex.m";
	regex: Regex;

Nedmail: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Message: adt {
	num:		int;		# fileno in the mailbox
	path:		string;		# /mail/fs/mbox/<num>
	from:		string;
	mto:		string;
	cc:		string;
	replyto:	string;
	date:		string;
	subject:	string;
	mtype:		string;
	disposition:	string;
	filename:	string;
	size:		int;
	deleted:	int;
};

FSROOT:	con "/mail/fs";
stdout: ref Iobuf;
mbname := "mbox";
mbox: array of ref Message;
cur := 0;			# index into mbox
startedfs := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		fatal("load bufio");
	regex = load Regex Regex->PATH;
	stdout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);

	file := "";
	argv = tl argv;
	while(argv != nil && len hd argv > 0 && (hd argv)[0] == '-'){
		opt := hd argv; argv = tl argv;
		case opt {
		"-f" =>	if(argv == nil) usage(); file = hd argv; argv = tl argv;
		"-m" =>	if(argv == nil) usage(); mbname = hd argv; argv = tl argv;
		* =>	usage();
		}
	}

	# make sure upas/fs is serving /mail/fs.
	(ok, nil) := sys->stat(FSROOT + "/ctl");
	if(ok < 0){
		if(file == "")
			fatal("/mail/fs not served and no -f mbox given");
		startfs(file);
	}

	readmbox();
	stdout.puts(sys->sprint("%d message%s\n", len mbox, plural(len mbox)));
	cur = 0;
	stdout.flush();

	cin := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	for(;;){
		prompt := ": ";
		if(len mbox > 0 && cur < len mbox)
			prompt = sys->sprint("%d: ", mbox[cur].num);
		stdout.puts(prompt);
		stdout.flush();
		line := cin.gets('\n');
		if(line == nil){		# EOF: flush deletes and go
			quit(1);
			break;
		}
		line = trim(line);
		if(docmd(line) < 0)		# q/x already quit
			break;
		stdout.flush();
	}
}

# ---- command dispatch ----

# returns -1 to exit the loop.
docmd(line: string): int
{
	# split leading address from the command.
	(addr, rest) := splitaddr(line);
	(cmd, args) := splitcmd(rest);

	# resolve the address (nil rest => the address itself means "go there
	# and print"; a bare empty line means "advance and print").
	target := cur;
	haveaddr := 0;
	if(addr != ""){
		(t, e) := resolve(addr);
		if(e != nil){
			stdout.puts("!" + e + "\n");
			return 0;
		}
		target = t;
		haveaddr = 1;
	}

	if(len mbox == 0 && cmd != "q" && cmd != "x" && cmd != "help" && cmd != "i" && cmd != "y"){
		stdout.puts("!no messages\n");
		return 0;
	}

	case cmd {
	"" =>
		if(!haveaddr){
			# bare newline: advance to the next message and print it.
			if(cur + 1 >= len mbox){
				stdout.puts("!address\n");
				return 0;
			}
			cur++;
		}else
			cur = target;
		pcmd(cur);
	"p" =>	cur = target; pcmd(cur);
	"P" =>	cur = target; rawcmd(cur);
	"\"" =>	cur = target; quotecmd(cur);
	"h" =>	cur = target; hcmd(cur);
	"H" =>	cur = target; mimecmd(cur);
	"b" =>	bcmd(target);
	"d" =>	cur = target; mbox[cur].deleted = 1;
	"u" =>	cur = target; mbox[cur].deleted = 0;
	"=" =>	stdout.puts(sys->sprint("%d\n", mbox[target].num));
	"w" =>	cur = target; savecmd(cur, args, 0);
	"s" =>	cur = target; savecmd(cur, args, 1);
	"y" or "i" =>
		resync();
	"q" =>	quit(1); return -1;
	"x" =>	quit(0); return -1;
	"help" or "?" =>
		helpcmd();
	* =>
		stdout.puts("!unknown command; type help\n");
	}
	return 0;
}

# ---- address resolution ----

splitaddr(line: string): (string, string)
{
	i := 0;
	# a leading address is digits, ., $, ^, +/-[n], or /regexp/
	if(i < len line){
		c := line[i];
		if(c == '/'){
			# /regexp/
			j := i + 1;
			while(j < len line && line[j] != '/')
				j++;
			if(j < len line)
				j++;			# closing slash
			return (line[i:j], trim(line[j:]));
		}
		if(c >= '0' && c <= '9' || c == '.' || c == '$' || c == '^' || c == '+' || c == '-'){
			j := i + 1;
			while(j < len line && (line[j] >= '0' && line[j] <= '9'))
				j++;
			return (line[i:j], trim(line[j:]));
		}
	}
	return ("", line);
}

splitcmd(rest: string): (string, string)
{
	rest = trim(rest);
	if(rest == "")
		return ("", "");
	# multi-char command words
	if(len rest >= 4 && rest[0:4] == "help")
		return ("help", trim(rest[4:]));
	# single-char command
	return (rest[0:1], trim(rest[1:]));
}

resolve(addr: string): (int, string)
{
	if(addr == "")
		return (cur, nil);
	case addr[0] {
	'.' =>	return (cur, nil);
	'$' =>	return (len mbox - 1, nil);
	'^' =>	return (0, nil);
	'+' =>
		n := 1;
		if(len addr > 1)
			n = int addr[1:];
		t := cur + n;
		if(t >= len mbox)
			return (0, "address");
		return (t, nil);
	'-' =>
		n := 1;
		if(len addr > 1)
			n = int addr[1:];
		t := cur - n;
		if(t < 0)
			return (0, "address");
		return (t, nil);
	'/' =>
		return search(addr);
	* =>
		# a message number (fileno)
		num := int addr;
		for(i := 0; i < len mbox; i++)
			if(mbox[i].num == num)
				return (i, nil);
		return (0, "address");
	}
}

search(addr: string): (int, string)
{
	if(regex == nil)
		return (0, "no regex module");
	pat := addr[1:];
	if(len pat > 0 && pat[len pat - 1] == '/')
		pat = pat[0:len pat - 1];
	(re, e) := regex->compile(pat, 0);
	if(re == nil)
		return (0, "bad regexp: " + e);
	for(k := 1; k <= len mbox; k++){
		i := (cur + k) % len mbox;
		m := mbox[i];
		hay := m.from + " " + m.subject + " " + m.mto;
		if(regex->execute(re, hay) != nil)
			return (i, nil);
	}
	return (0, "search failed");
}

# ---- commands ----

pcmd(i: int)
{
	if(i < 0 || i >= len mbox)
		return;
	m := mbox[i];
	# a short header block, then the decoded body.
	stdout.puts(sys->sprint("==> %d (%d bytes)\n", m.num, m.size));
	if(m.from != "")
		stdout.puts("From: " + m.from + "\n");
	if(m.mto != "")
		stdout.puts("To: " + m.mto + "\n");
	if(m.cc != "")
		stdout.puts("Cc: " + m.cc + "\n");
	if(m.date != "")
		stdout.puts("Date: " + m.date + "\n");
	if(m.subject != "")
		stdout.puts("Subject: " + m.subject + "\n");
	stdout.puts("\n");
	body := readfile(m.path + "/body");
	if(body != nil)
		stdout.write(body, len body);
	stdout.puts("\n");
}

rawcmd(i: int)
{
	if(i < 0 || i >= len mbox)
		return;
	raw := readfile(mbox[i].path + "/raw");
	if(raw != nil)
		stdout.write(raw, len raw);
	stdout.puts("\n");
}

quotecmd(i: int)
{
	if(i < 0 || i >= len mbox)
		return;
	m := mbox[i];
	who := m.from;
	if(who == "")
		who = "someone";
	stdout.puts(who + " writes:\n");
	body := readfile(m.path + "/body");
	if(body == nil)
		return;
	(nil, lines) := sys->tokenize(string body, "\n");
	for(; lines != nil; lines = tl lines)
		stdout.puts("> " + hd lines + "\n");
}

hcmd(i: int)
{
	if(i >= 0 && i < len mbox)
		stdout.puts(summary(i));
}

bcmd(start: int)
{
	for(i := start; i < len mbox && i < start + 10; i++)
		stdout.puts(summary(i));
}

summary(i: int): string
{
	m := mbox[i];
	mark := " ";
	if(m.deleted)
		mark = "d";
	if(i == cur)
		mark = ">";
	subj := m.subject;
	if(subj == "")
		subj = "(no subject)";
	return sys->sprint("%s%3d %-20.20s %-.40s\n", mark, m.num, trunc(m.from, 20), subj);
}

mimecmd(i: int)
{
	if(i < 0 || i >= len mbox)
		return;
	m := mbox[i];
	stdout.puts(sys->sprint("%d %s", m.num, m.mtype));
	if(m.filename != "")
		stdout.puts(" " + m.filename);
	stdout.puts("\n");
	mimetree(m.path, 1);
}

mimetree(path: string, depth: int)
{
	for(k := 1;; k++){
		p := path + "/" + string k;
		(ok, nil) := sys->stat(p);
		if(ok < 0)
			break;
		ty := string readfile(p + "/type");
		fname := string readfile(p + "/filename");
		ind := "";
		for(d := 0; d < depth; d++)
			ind += "  ";
		stdout.puts(sys->sprint("%s%d %s", ind, k, ty));
		if(fname != "")
			stdout.puts(" " + fname);
		stdout.puts("\n");
		mimetree(p, depth + 1);
	}
}

savecmd(i: int, arg: string, raw: int)
{
	if(arg == ""){
		stdout.puts("!usage: w|s file\n");
		return;
	}
	m := mbox[i];
	src := "/body";
	mode := Sys->OWRITE|Sys->OTRUNC;
	if(raw){
		src = "/raw";
		mode = Sys->OWRITE;		# s appends
	}
	data := readfile(m.path + src);
	if(data == nil){
		stdout.puts("!nothing to save\n");
		return;
	}
	fd: ref Sys->FD;
	if(raw){
		fd = sys->open(arg, Sys->OWRITE);
		if(fd == nil)
			fd = sys->create(arg, Sys->OWRITE, 8r600);
		if(fd != nil)
			sys->seek(fd, big 0, Sys->SEEKEND);
	}else
		fd = sys->create(arg, mode, 8r600);
	if(fd == nil){
		stdout.puts(sys->sprint("!can't open %s: %r\n", arg));
		return;
	}
	if(raw){
		# prefix a unix From line so the file is a valid mbox.
		hdr := array of byte ("From nedmail\n");
		sys->write(fd, hdr, len hdr);
	}
	sys->write(fd, data, len data);
	stdout.puts(sys->sprint("saved %d bytes to %s\n", len data, arg));
}

resync()
{
	# remember the current message number, re-read, restore.
	curnum := -1;
	if(cur < len mbox)
		curnum = mbox[cur].num;
	readmbox();
	cur = 0;
	for(i := 0; i < len mbox; i++)
		if(mbox[i].num == curnum)
			cur = i;
	stdout.puts(sys->sprint("%d message%s\n", len mbox, plural(len mbox)));
}

helpcmd()
{
	stdout.puts(
	"p print   P raw   \" quote   h summary   H mime   b next 10\n" +
	"d delete   u undelete   = number   w file   s file\n" +
	"y/i resync   q quit(flush)   x quit(noflush)   help\n" +
	"addresses: N . $ ^ +n -n /regexp/\n");
}

# flush deleted messages through /mail/fs/ctl, then exit.
quit(flush: int)
{
	if(flush){
		nums := "";
		n := 0;
		for(i := 0; i < len mbox; i++)
			if(mbox[i].deleted){
				nums += " " + string mbox[i].num;
				n++;
			}
		if(n > 0){
			fd := sys->open(FSROOT + "/ctl", Sys->OWRITE);
			if(fd == nil)
				stdout.puts(sys->sprint("!can't open ctl: %r\n"));
			else{
				cmd := array of byte ("delete " + mbname + nums);
				if(sys->write(fd, cmd, len cmd) < 0)
					stdout.puts(sys->sprint("!delete failed: %r\n"));
				else
					stdout.puts(sys->sprint("deleted %d message%s\n", n, plural(n)));
			}
		}
	}
	stdout.flush();
	if(startedfs)
		sys->unmount(nil, FSROOT);
}

# ---- mailbox reading ----

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
	# sort ascending (simple insertion into an array)
	a := array[len nums] of int;
	k := 0;
	for(; nums != nil; nums = tl nums)
		a[k++] = hd nums;
	for(i := 0; i < len a; i++)
		for(j := i + 1; j < len a; j++)
			if(a[j] < a[i]){
				t := a[i]; a[i] = a[j]; a[j] = t;
			}
	mbox = array[len a] of ref Message;
	for(i = 0; i < len a; i++)
		mbox[i] = readmessage(dir + "/" + string a[i], a[i]);
}

readmessage(path: string, num: int): ref Message
{
	m := ref Message;
	m.num = num;
	m.path = path;
	m.deleted = 0;
	info := string readfile(path + "/info");
	f := lineize(info, 10);
	m.from = f[0];
	m.mto = f[1];
	m.cc = f[2];
	m.replyto = f[3];
	m.date = f[4];
	m.subject = f[5];
	m.mtype = f[6];
	m.disposition = f[7];
	m.filename = f[8];
	m.size = len readfile(path + "/raw");
	return m;
}

# split the first n lines of s into an array of exactly n strings (missing
# lines are ""), matching Plan 9's lineize used on the info file.
lineize(s: string, n: int): array of string
{
	a := array[n] of string;
	for(i := 0; i < n; i++)
		a[i] = "";
	i = 0;
	start := 0;
	for(j := 0; j < len s && i < n; j++){
		if(s[j] == '\n'){
			a[i++] = s[start:j];
			start = j + 1;
		}
	}
	if(i < n && start < len s)
		a[i] = s[start:];
	return a;
}

startfs(file: string)
{
	# spawn upas/fs -m /mail/fs <file> and wait for the ctl file.
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

runfs(file: string)
{
	argv := "upas/fs" :: "-m" :: FSROOT :: file :: nil;
	cmd := load Command "/dis/upas/fs.dis";
	if(cmd == nil){
		sys->fprint(sys->fildes(2), "nedmail: load upas/fs: %r\n");
		return;
	}
	cmd->init(nil, argv);
}

Command: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# ---- helpers ----

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

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j - 1] == ' ' || s[j - 1] == '\t' || s[j - 1] == '\r' || s[j - 1] == '\n'))
		j--;
	return s[i:j];
}

trunc(s: string, n: int): string
{
	if(len s <= n)
		return s;
	return s[0:n];
}

plural(n: int): string
{
	if(n == 1)
		return "";
	return "s";
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: upas/nedmail [-f mbox] [-m mailbox]\n");
	raise "fail:usage";
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "nedmail: %s\n", s);
	raise "fail:error";
}
