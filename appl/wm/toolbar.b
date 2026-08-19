implement Toolbar;

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Screen, Display, Image, Rect, Point, Wmcontext, Pointer: import draw;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "sh.m";
	shell: Sh;
	Listnode, Context: import shell;

include "arg.m";

include "env.m";

include "string.m";
	str: String;

include "arrays.m";
	arrays: Arrays;

myselfbuiltin: Shellbuiltin;

Toolbar: module 
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
	initbuiltin: fn(c: ref Context, sh: Sh): string;
	runbuiltin: fn(c: ref Context, sh: Sh,
			cmd: list of ref Listnode, last: int): string;
	runsbuiltin: fn(c: ref Context, sh: Sh,
			cmd: list of ref Listnode): list of ref Listnode;
	whatis: fn(c: ref Sh->Context, sh: Sh, name: string, wtype: int): string;
	getself: fn(): Shellbuiltin;
};

MAXCONSOLELINES:	con 1024;

font: string;
icon: string = "vitasmall.bit";

# execute this if no menu items have been created
# by the init script.
defaultscript :=
	"{menu shell " +
		"{{autoload=std; load $autoload; pctl newpgrp; wm/sh}&}}";

tbtop: ref Tk->Toplevel;
screenr: Rect;

badmodule(p: string)
{
	sys->fprint(stderr(), "toolbar: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

# Apply join "rect" (must not drop it — that left screenr as 0,480,0,480).
waitctl(top: ref Tk->Toplevel, ready: chan of int)
{
	c: string;

	alt{
	c = <-top.ctxt.ctl =>
		;
	c = <-top.wreq =>
		;
	}
	if(c != nil)
		tkclient->wmctl(top, c);
	ready <-= 1;
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys  = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		badmodule(Draw->PATH);
	tk   = load Tk Tk->PATH;
	if(tk == nil)
		badmodule(Tk->PATH);

	str = load String String->PATH;
	if(str == nil)
		badmodule(String->PATH);

	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		badmodule(Tkclient->PATH);
	tkclient->init();

	shell = load Sh Sh->PATH;
	if (shell == nil)
		badmodule(Sh->PATH);
	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmodule(Arg->PATH);
	env := load Env Env->PATH;
	if(env == nil)
		badmodule(Env->PATH);
	arrays = load Arrays Arrays->PATH;
	if(arrays == nil)
		badmodule(Arrays->PATH);

	myselfbuiltin = load Shellbuiltin "$self";
	if (myselfbuiltin == nil)
		badmodule("$self(Shellbuiltin)");

	sys->pctl(Sys->NEWPGRP|Sys->FORKNS, nil);

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#s", "/chan", sys->MBEFORE);

	arg->init(argv);
	arg->setusage("toolbar [-s] [-p] [-f font] [-i icon.bit]");
	startmenu := 1;
#	ownsnarf := (sys->open("/chan/snarf", Sys->ORDWR) == nil);
	ownsnarf := sys->stat("/chan/snarf").t0 < 0;
	while((c := arg->opt()) != 0){
		case c {
		's' =>
			startmenu = 0;
		'p' =>
			ownsnarf = 1;
		'f' =>
			font = arg->earg();
		'i' =>
			icon = arg->earg();
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	arg = nil;

	if (ctxt == nil){
		sys->fprint(sys->fildes(2), "toolbar: must run under a window manager\n");
		raise "fail:no wm";
	}

	if(font == nil){
		font = "/fonts/misc/latin1.6x13.font";
		f := env->getenv("font");
		if(f != nil)
			font = f;

		font = " -font " + font + " ";
	}

	exec := chan of string;
	task := chan of string;

	tbtop = toolbar(ctxt, startmenu, exec, task);
	# Apply join "rect" before !reshape (must not drop it).
	ready := chan of int;
	spawn waitctl(tbtop, ready);
	<-ready;
	layout(tbtop);
	tkclient->startinput(tbtop, "ptr" :: "control" :: nil);

	shctxt := Context.new(ctxt);
	shctxt.addmodule("wm", myselfbuiltin);

	snarfIO: ref Sys->FileIO;
	if(ownsnarf){
		snarfIO = sys->file2chan("/chan", "snarf");
		if(snarfIO == nil)
			fatal(sys->sprint("cannot make /chan/snarf: %r"));
	}else
		snarfIO = ref Sys->FileIO(chan of (big, int, int, Sys->Rread), chan of (big, array of byte, int, Sys->Rwrite));
	sync := chan of string;
	spawn consoleproc(ctxt, sync);
	if ((err := <-sync) != nil){
sys->print("error: %s\n", err);
		fatal(err);
	}

	setupfinished := chan of int;
	donesetup := 0;
	spawn setup(shctxt, setupfinished);

	snarf: array of byte;
#	write("/prog/"+string sys->pctl(0, nil)+"/ctl", "restricted"); # for testing
	for(;;) alt{
	k := <-tbtop.ctxt.kbd =>
		tk->keyboard(tbtop, k);
	m := <-tbtop.ctxt.ptr =>
		tk->pointer(tbtop, *m);
	s := <-tbtop.ctxt.ctl =>
		wmctl(tbtop, s);
	s := <-tbtop.wreq =>
		# Tk's own geometry manager posts here when it thinks the
		# toplevel's size needs to change - using ITS OWN local
		# coordinate origin (0,0), since Tk has no notion of where
		# the window sits on screen (that's the WM's job). wmctl()'s
		# generic fallback would forward a "!reshape" request as-is,
		# misread by the server as an ABSOLUTE screen position -
		# e.g. "(0,0)-(width,32)" instead of the correct bottom-pinned
		# rect layout() already computed - clobbering a window that
		# was already positioned correctly. layout() is the sole
		# authoritative source for absolute placement (it runs on
		# every "rect" notification and explicitly calls
		# tkclient->onscreen(tbtop, "exact") with the real rect), so
		# drop *only* a reshape of the toplevel itself (name ".")
		# from this channel. A "!reshape" naming some *other* window
		# is libtk's tkexterncreatewin() (windw.c) asking wmreq1()
		# (tkclient.b) to actually allocate that window's backing
		# image - this is how every Tk "external window" gets made,
		# popup menus included (its own comment: "for a choicebutton
		# menu, use the name of the choicebutton which created it").
		# Dropping those unconditionally, as an earlier version of
		# this guard did, left every popup menu - including the
		# toolbar's own Start menu - with no backing image at all:
		# the click was received and handled, but the menu had
		# nothing to display into, so it looked like the click did
		# nothing.
		if(!isreshapeof(s, "."))
			wmctl(tbtop, s);
	s := <-exec =>
		# guard against parallel access to the shctxt environment
		if (donesetup){
			{
 				shctxt.run(ref Listnode(nil, s) :: nil, 0);
			} exception e {
			"fail:*" =>	sys->print("wm/toolbar: exec %s failed: %s\n", s, e);
			}
		}
	detask := <-task =>
		deiconify(detask);
	(off, data, nil, wc) := <-snarfIO.write =>
		if(wc == nil)
			break;
		if (off == big 0)			# write at zero truncates
			snarf = data;
		else {
			if (off + big len data > big len snarf) {
				nsnarf := array[int off + len data] of byte; # TODO potential bug truncating big to int
				nsnarf[0:] = snarf;
				snarf = nsnarf;
			}
			snarf[int off:] = data; # TODO potential bug truncating big to int
		}
		hostsnarfput(snarf);
		wc <-= (len data, "");
	(off, nbytes, nil, rc) := <-snarfIO.read =>
		if(rc == nil)
			break;
		if(off == big 0){
			host := hostsnarfget();
			if(host != nil)
				snarf = host;
		}
		if (off >= big len snarf) {
			rc <-= (nil, "");		# XXX alt
			break;
		}
		e := off + big nbytes;
		if (e > big len snarf)
			e = big len snarf;
		rc <-= (snarf[int off:int e], "");	# XXX alt # TODO potential bug truncating big to int
	donesetup = <-setupfinished =>
		;	
	}
}

# /dev/snarf is the emulator host clipboard.  /chan/snarf remains the public
# WM endpoint, but mirrors it so existing applications and Acme need no changes.
hostsnarfget(): array of byte
{
	fd := sys->open("/dev/snarf", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[100*1024] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return b[0:n];
}

hostsnarfput(b: array of byte)
{
	fd := sys->open("/dev/snarf", Sys->OWRITE);
	if(fd != nil && len b > 0)
		sys->write(fd, b, len b);
}

wmctl(top: ref Tk->Toplevel, c: string)
{
	args := str->unquoted(c);
	if(args == nil)
		return;
	n := len args;

	case hd args{
	"request" =>
		# request clientid args...
		if(n < 3)
			return;
		args = tl args;
		clientid := hd args;
		args = tl args;
		err := handlerequest(clientid, args);
		if(err != nil)
			sys->fprint(sys->fildes(2), "toolbar: bad wmctl request %#q: %s\n", c, err);
	"newclient" =>
		# newclient id
		;
	"delclient" =>
		# delclient id
		deiconify(hd tl args);
	"rect" =>
		tkclient->wmctl(top, c);
		layout(top);
	* =>
		tkclient->wmctl(top, c);
	}
}

handlerequest(clientid: string, args: list of string): string
{
	n := len args;
	case hd args {
	"task" =>
		# task name
		if(n != 2)
			return "no task label given";
		iconify(clientid, hd tl args);
	"untask" or
	"unhide" =>
		deiconify(clientid);
	* =>
		return "unknown request";
	}
	return nil;
}

iconify(id, label: string)
{
	label = condenselabel(label);
	e := tk->cmd(tbtop, "button .toolbar." +id+" -command {send task "+id+"} -takefocus 0");
	cmd(tbtop, ".toolbar." +id+" configure" + font + " -text '" + label);
	if(e[0] != '!')
		cmd(tbtop, "pack .toolbar."+id+" -side left -fill y");
	cmd(tbtop, "update");
}

deiconify(id: string)
{
	e := tk->cmd(tbtop, "destroy .toolbar."+id);
	if(e == nil){
		tkclient->wmctl(tbtop, sys->sprint("ctl %q untask", id));
		tkclient->wmctl(tbtop, sys->sprint("ctl %q kbdfocus 1", id));
	}
	cmd(tbtop, "update");
}

layout(top: ref Tk->Toplevel)
{
	r := top.screenr;
	h := 32;
	if(r.dy() < 480)
		h = tk->rect(top, ".b", Tk->Border|Tk->Required).dy();
	# Keep bar inside ramfb; "place" near y=480 has hit bad delta on virt.
	if(r.max.y - h < r.min.y)
		h = r.dy();
	if(h < 1)
		h = 32;
	if(r.dx() <= 0 || r.dy() <= 0){
		sys->print("toolbar: bad screenr %d %d %d %d\n",
			r.min.x, r.min.y, r.max.x, r.max.y);
		r = ((0, 0), (640, 480));
	}
	cmd(top, ". configure -x " + string r.min.x +
			font +
			" -y " + string (r.max.y - h) +
			" -width " + string r.dx() +
			" -height " + string h);
	cmd(top, "update");
	# Any duplicate "!reshape" Tk's own geometry manager posts to
	# tbtop.wreq as a side effect of the configure/update above is
	# filtered out where it's received (see the main loop) - this call
	# is the sole authoritative source for absolute screen placement.
	tkclient->onscreen(tbtop, "exact");
	# onscreen("exact") blocks until the server hands back a freshly
	# (re)allocated backing image at the new size; the "update" above
	# ran against the *old* one, before this call requested the new
	# size, so it can't have painted anything into a newly exposed
	# region on growth. See the identical fix (with fuller explanation)
	# in appl/wm/pinboard.b's relayout() - force a redraw now that the
	# new backing store is actually in place.
	cmd(top, "update");
}

toolbar(ctxt: ref Draw->Context, startmenu: int,
		exec, task: chan of string): ref Tk->Toplevel
{
	(tbtop, nil) = tkclient->toplevel(ctxt, nil, nil, Tkclient->Plain);
	screenr = tbtop.screenr;

	cmd(tbtop, "button .b -text {XXX}");
	cmd(tbtop, "pack propagate . 0");

	tk->namechan(tbtop, exec, "exec");
	tk->namechan(tbtop, task, "task");
	cmd(tbtop, "frame .toolbar");
	if (startmenu) {
		cmd(tbtop, "menubutton .toolbar.start -menu .m -borderwidth 0 -bitmap " + icon);
		cmd(tbtop, "pack .toolbar.start -side left");
	}
	cmd(tbtop, "pack .toolbar -fill x");
	cmd(tbtop, "menu .m");
	return tbtop;
}

setup(shctxt: ref Context, finished: chan of int)
{
	ctxt := shctxt.copy(0);
	ctxt.run(shell->stringlist2list("run"::"/lib/wmsetup"::nil), 0);
	# if no items in menu, then create some.
	if (tk->cmd(tbtop, ".m type 0")[0] == '!')
		ctxt.run(shell->stringlist2list(defaultscript::nil), 0);
	cmd(tbtop, "update");
	finished <-= 1;
}

condenselabel(label: string): string
{
	if(len label > 15){
		new := "";
		l := 0;
		while(len label > 15 && l < 3) {
			new += label[0:15]+"\n";
			label = label[15:];
			for(v := 0; v < len label; v++)
				if(label[v] != ' ')
					break;
			label = label[v:];
			l++;
		}
		label = new + label;
	}
	return label;
}

initbuiltin(ctxt: ref Context, nil: Sh): string
{
	if (tbtop == nil) {
		sys = load Sys Sys->PATH;
		sys->fprint(sys->fildes(2), "wm: cannot load wm as a builtin\n");
		raise "fail:usage";
	}
	ctxt.addbuiltin("menu", myselfbuiltin);
	ctxt.addbuiltin("delmenu", myselfbuiltin);
	ctxt.addbuiltin("error", myselfbuiltin);
	return nil;
}

whatis(nil: ref Sh->Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

runbuiltin(c: ref Context, sh: Sh,
			cmd: list of ref Listnode, nil: int): string
{
	case (hd cmd).word {
	"menu" =>	return builtin_menu(c, sh, cmd);
	"delmenu" =>	return builtin_delmenu(c, sh, cmd);
	}
	return nil;
}

runsbuiltin(nil: ref Context, nil: Sh,
			nil: list of ref Listnode): list of ref Listnode
{
	return nil;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

word(ln: ref Listnode): string
{
	if (ln.word != nil)
		return ln.word;
	if (ln.cmd != nil)
		return shell->cmd2string(ln.cmd);
	return nil;
}

menupath(title: string): string
{
	mpath := ".m."+title;
	for(j := 0; j < len mpath; j++)
		if(mpath[j] == ' ')
			mpath[j] = '_';
	return mpath;
}

builtin_menu(nil: ref Context, nil: Sh, argv: list of ref Listnode): string
{
	n := len argv;
	if (n < 3 || n > 4) {
		sys->fprint(stderr(), "usage: menu topmenu [ secondmenu ] command\n");
		raise "fail:usage";
	}
	primary := (hd tl argv).word;
	argv = tl tl argv;

	cmd(tbtop, ".m configure " + font);

	if (n == 3) {
		w := word(hd argv);
		if (len w == 0)
			cmd(tbtop, ".m insert 0 separator");
		else
			cmd(tbtop, ".m insert 0 command -label " + tk->quote(primary) +
				" -command {send exec " + w + "}");
	} else {
		secondary := (hd argv).word;
		argv = tl argv;

		mpath := menupath(primary);

		e := tk->cmd(tbtop, mpath+" cget -width");
		if(e[0] == '!') {
			cmd(tbtop, "menu "+mpath);
			cmd(tbtop, ".m insert 0 cascade -label "+tk->quote(primary)+" -menu "+mpath);
		}
		w := word(hd argv);
		if (len w == 0){
			cmd(tbtop, mpath + " insert 0 separator");
		}else{
			# Set font for entries
			cmd(tbtop, mpath+" configure " + font);

			cmd(tbtop, mpath+" insert 0 command -label "+tk->quote(secondary)+
				" -command {send exec "+w+"}");
		}

	}
	return nil;
}

builtin_delmenu(nil: ref Context, nil: Sh, nil: list of ref Listnode): string
{
	delmenu(".m");
	cmd(tbtop, "menu .m");
	return nil;
}

delmenu(m: string)
{
	for (i := int cmd(tbtop, m + " index end"); i >= 0; i--)
		if (cmd(tbtop, m + " type " + string i) == "cascade")
			delmenu(cmd(tbtop, m + " entrycget " + string i + " -menu"));
	cmd(tbtop, "destroy " + m);
}

getself(): Shellbuiltin
{
	return myselfbuiltin;
}

# True iff s is a "!reshape <name> ..." wreq request naming window `name`
# specifically (see libtk/windw.c's tkexterncreatewin(), the sole source of
# these messages: format is "!reshape %s %d %d %d %d %d", the %s being the
# window's own path - "." for the toplevel itself, anything else for a
# Tk-created external window such as a popup menu).
isreshapeof(s, name: string): int
{
	if(len s < 9 || s[0:8] != "!reshape" || s[8] != ' ')
		return 0;
	(word, nil) := str->splitl(s[9:], " ");
	return word == name;
}

cmd(top: ref Tk->Toplevel, c: string): string
{
	s := tk->cmd(top, c);
	if (s != nil && s[0] == '!')
		sys->fprint(stderr(), "tk error on %#q: %s\n", c, s);
	return s;
}

kill(pid: int, note: string): int
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm: %s\n", s);
	kill(sys->pctl(0, nil), "killgrp");
	raise "fail:error";
}

bufferproc(in, out: chan of string)
{
	h, t: list of string;
	dummyout := chan of string;
	for(;;){
		outc := dummyout;
		s: string;
		if(h != nil || t != nil){
			outc = out;
			if(h == nil)
				for(; t != nil; t = tl t)
					h = hd t :: h;
			s = hd h;
		}
		alt{
		x := <-in =>
			t = x :: t;
		outc <-= s =>
			h = tl h;
		}
	}
}

con_cfg := array[] of
{
	"frame .cons",
	"scrollbar .cons.scroll -command {.cons.t yview}",

	"text .cons.t -width 60w -height 15w -bg white "+
		"-fg black -yscrollcommand {.cons.scroll set} $font",
		#"",

	"pack .cons.scroll -side left -fill y",

	"pack .cons.t -fill both -expand 1",

	"pack .cons -expand 1 -fill both",

	"pack propagate . 0",

	"update"
};

nlines := 0;		# transcript length

consoleproc(ctxt: ref Draw->Context, sync: chan of string)
{
	iostdout := sys->file2chan("/chan", "wmstdout");
	if(iostdout == nil){
		sync <-= sys->sprint("cannot make /chan/wmstdout: %r");
		return;
	}
	iostderr := sys->file2chan("/chan", "wmstderr");
	if(iostderr == nil){
		sync <-= sys->sprint("cannot make /chan/wmstdout: %r");
		return;
	}

	sync <-= nil;

	(top, titlectl) := tkclient->toplevel(ctxt, "", "Log", tkclient->Appl); 

	# Patch in font - why was this an array to start?
	con_cfg = arrays->map(con_cfg, fontify);

	for(i := 0; i < len con_cfg; i++)
		cmd(top, con_cfg[i]);

	r := tk->rect(top, ".", Tk->Border|Tk->Required);
	cmd(top, ". configure " + font + " -x " + string ((top.screenr.dx() - r.dx()) / 2 + top.screenr.min.x) +
				" -y " + string (r.dy() / 3 + top.screenr.min.y));

	tkclient->startinput(top, "ptr"::"kbd"::nil);
	tkclient->onscreen(top, "onscreen");
	tkclient->wmctl(top, "task");

	for(;;) alt {
	c := <-titlectl or
	c = <-top.wreq or
	c = <-top.ctxt.ctl =>
		if(c == "exit")
			c = "task";
		tkclient->wmctl(top, c);
	c := <-top.ctxt.kbd =>
		tk->keyboard(top, c);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	(nil, nil, nil, rc) := <-iostdout.read =>
		if(rc != nil)
			rc <-= (nil, "inappropriate use of file");
	(nil, nil, nil, rc) := <-iostderr.read =>
		if(rc != nil)
			rc <-= (nil, "inappropriate use of file");
	(nil, data, nil, wc) := <-iostdout.write =>
		conout(top, data, wc);
	(nil, data, nil, wc) := <-iostderr.write =>
		conout(top, data, wc);
		if(wc != nil)
			tkclient->wmctl(top, "untask");
	}
}

conout(top: ref Tk->Toplevel, data: array of byte, wc: Sys->Rwrite)
{
	if(wc == nil)
		return;

	s := string data;
	tk->cmd(top, ".cons.t insert end '"+ s);
	alt{
	wc <-= (len data, nil) =>;
	* =>;
	}

	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			nlines++;
	if(nlines > MAXCONSOLELINES){
		cmd(top, ".cons.t delete 1.0 " + string (nlines/4) + ".0; update");
		nlines -= nlines / 4;
	}

	tk->cmd(top, ".cons.t see end; update");
}

fontify(s: string): string {
	return str->replace(s, "$font", font, -1);
}
