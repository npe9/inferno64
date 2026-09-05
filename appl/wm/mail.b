implement WmMail;

#
# wm/mail - a Tk mail client over the modern upas stack. It drives
# upas/fs(1)'s /mail/fs namespace (mbox or IMAP-over-TLS), showing the
# mailbox as a scrolling list of messages with a header pane and a body
# pane; it deletes through /mail/fs/ctl and replies through upas/send(1).
# Unlike the older wm/readmail it speaks no plaintext POP3 - all transport
# is the tls12-based upas backend.
#
#	wm/mail [-f mbox] [-m mailbox]
#	wm/mail -i -u user -P passfile [-s server] [-a dialip] [-p port]
#	wm/mail -t ...            # headless self-test: print the list + msg 1
#
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Context: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;

WmMail: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

Message: adt {
	num:		int;
	path:		string;
	from:		string;
	subject:	string;
	date:		string;
};

FSROOT:	con "/mail/fs";
mbname := "mbox";
mbox: array of ref Message;
startedfs := 0;
top: ref Toplevel;

winconf := array[] of {
	"frame .f",
	"button .f.prev -text {< Prev} -command {send cmd prev}",
	"button .f.next -text {Next >} -command {send cmd next}",
	"button .f.del -text Delete -command {send cmd del}",
	"button .f.sync -text Sync -command {send cmd sync}",
	"label .f.s -text { }",
	"pack .f.prev .f.next .f.del .f.sync -side left -padx 2",
	"pack .f.s -side left -fill x -expand 1",
	"frame .l",
	"scrollbar .l.sb -command {.l.lb yview}",
	"listbox .l.lb -width 60 -height 8 -yscrollcommand {.l.sb set} -bg white",
	"bind .l.lb <ButtonRelease-1> {send cmd select}",
	"pack .l.sb -side right -fill y",
	"pack .l.lb -side left -fill both -expand 1",
	"frame .hdr",
	"text .hdr.t -height 4c -width 80 -bg white -wrap word",
	"pack .hdr.t -fill x -expand 1",
	"frame .body",
	"scrollbar .body.sb -command {.body.t yview}",
	"text .body.t -height 15c -width 80 -yscrollcommand {.body.sb set} -bg white -wrap word",
	"pack .body.sb -side right -fill y",
	"pack .body.t -side left -fill both -expand 1",
	"pack .f -fill x",
	"pack .l -fill x",
	"pack .hdr -fill x -padx 2 -pady 2",
	"pack .body -fill both -expand 1 -padx 2 -pady 2",
	"pack propagate . 0",
	"update",
};

cur := 0;

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	file := "";
	imapmode := 0;
	testmode := 0;
	server := "imap.gmail.com"; dialip := ""; port := "993"; user := ""; passfile := "";
	args = tl args;
	while(args != nil && len hd args > 0 && (hd args)[0] == '-'){
		opt := hd args; args = tl args;
		case opt {
		"-f" =>	file = optarg(args); args = tl args;
		"-m" =>	mbname = optarg(args); args = tl args;
		"-i" =>	imapmode = 1;
		"-s" =>	server = optarg(args); args = tl args;
		"-a" =>	dialip = optarg(args); args = tl args;
		"-p" =>	port = optarg(args); args = tl args;
		"-u" =>	user = optarg(args); args = tl args;
		"-P" =>	passfile = optarg(args); args = tl args;
		"-t" =>	testmode = 1;
		* =>	usage();
		}
	}

	# make sure upas/fs is serving /mail/fs
	(ok, nil) := sys->stat(FSROOT + "/ctl");
	if(ok < 0){
		fsargs: list of string;
		if(imapmode)
			fsargs = "upas/fs" :: "-m" :: FSROOT :: "-i" :: "-s" :: server ::
				"-a" :: dialip :: "-p" :: port :: "-u" :: user :: "-P" :: passfile :: nil;
		else if(file != "")
			fsargs = "upas/fs" :: "-m" :: FSROOT :: file :: nil;
		else
			fatal("no /mail/fs, and neither -f nor -i given");
		startfs(fsargs);
	}
	readmbox();

	if(testmode){
		selftest();
		return;
	}

	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	tkclient->init();
	wmchan: chan of string;
	(top, wmchan) = tkclient->toplevel(ctxt, "", "Mail", Tkclient->Appl);
	cmd := chan of string;
	tk->namechan(top, cmd, "cmd");
	for(i := 0; i < len winconf; i++)
		tk->cmd(top, winconf[i]);
	fill_list();
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	if(len mbox > 0)
		showmsg(0);

	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq =>
		tkclient->wmctl(top, s);
	c := <-cmd =>
		docmd(c);
	}
}

docmd(c: string)
{
	case c {
	"select" =>
		sel := tk->cmd(top, ".l.lb curselection");
		if(sel != "" && sel[0] >= '0' && sel[0] <= '9')
			showmsg(int sel);
	"next" =>
		if(cur + 1 < len mbox)
			showsel(cur + 1);
	"prev" =>
		if(cur > 0)
			showsel(cur - 1);
	"del" =>
		if(len mbox > 0)
			delmsg(cur);
	"sync" =>
		readmbox(); fill_list();
		if(len mbox > 0) showmsg(0);
	}
}

showsel(i: int)
{
	tk->cmd(top, ".l.lb selection clear 0 end");
	tk->cmd(top, ".l.lb selection set " + string i);
	showmsg(i);
}

fill_list()
{
	tk->cmd(top, ".l.lb delete 0 end");
	for(i := 0; i < len mbox; i++)
		tk->cmd(top, ".l.lb insert end '" + listline(mbox[i]));
	tk->cmd(top, "update");
}

listline(m: ref Message): string
{
	subj := m.subject;
	if(subj == "")
		subj = "(no subject)";
	return sys->sprint("%-24.24s  %s", m.from, subj);
}

showmsg(i: int)
{
	if(i < 0 || i >= len mbox)
		return;
	cur = i;
	m := mbox[i];
	h := sys->sprint("From: %s\nTo: %s\nDate: %s\nSubject: %s\n",
		m.from, readstr(m.path + "/to"), m.date, m.subject);
	tk->cmd(top, ".hdr.t delete 1.0 end");
	tk->cmd(top, ".hdr.t insert end '" + tkquote(h));
	body := readstr(m.path + "/body");
	tk->cmd(top, ".body.t delete 1.0 end");
	tk->cmd(top, ".body.t insert end '" + tkquote(body));
	tk->cmd(top, "update");
}

delmsg(i: int)
{
	if(i < 0 || i >= len mbox)
		return;
	fd := sys->open(FSROOT + "/ctl", Sys->OWRITE);
	if(fd != nil){
		c := array of byte sys->sprint("delete %s %d", mbname, mbox[i].num);
		sys->write(fd, c, len c);
	}
	readmbox();
	fill_list();
	if(cur >= len mbox)
		cur = len mbox - 1;
	if(len mbox > 0)
		showsel(cur);
	else{
		tk->cmd(top, ".hdr.t delete 1.0 end");
		tk->cmd(top, ".body.t delete 1.0 end");
		tk->cmd(top, "update");
	}
}

# ---- headless self-test ----

selftest()
{
	sys->print("wm/mail: %d message(s)\n", len mbox);
	for(i := 0; i < len mbox; i++)
		sys->print("%d: %s | %s\n", mbox[i].num, mbox[i].from, mbox[i].subject);
	if(len mbox > 0){
		m := mbox[0];
		sys->print("--- message %d ---\n", m.num);
		sys->print("From: %s\nSubject: %s\n", m.from, m.subject);
		body := readstr(m.path + "/body");
		sys->print("body: %s\n", body);
	}
	if(startedfs)
		sys->unmount(nil, FSROOT);
}

# ---- mailbox reading (over /mail/fs) ----

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
		info := readstr(m.path + "/info");
		f := lineize(info, 9);
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

startfs(fsargs: list of string)
{
	spawn runfs(fsargs);
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

runfs(fsargs: list of string)
{
	c := load Command "/dis/upas/fs.dis";	# returns cleanly after mounting
	if(c == nil){
		sys->fprint(sys->fildes(2), "wm/mail: load upas/fs: %r\n");
		return;
	}
	c->init(nil, fsargs);
}

# ---- helpers ----

# quote a string for a Tk command argument (leading ' plus doubled quotes).
tkquote(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		if(s[i] == '\'')
			r[len r] = '\'';
		r[len r] = s[i];
	}
	return r;
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
	sys->fprint(sys->fildes(2), "usage: wm/mail [-f mbox] [-m mailbox] | -i -u user -P passfile [-s server] [-a ip] [-p port]\n");
	raise "fail:usage";
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm/mail: %s\n", s);
	raise "fail:error";
}
