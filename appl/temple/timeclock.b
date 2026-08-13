implement Timeclock;

# TempleOS Apps/TimeClock — Tk stand-in for DolDoc punch UI
# GAP: DolDoc forms / CDate / .DATA.Z → Tk + plain text file ~/temple-timeclock.txt

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

include "daytime.m";
	daytime: Daytime;

Timeclock: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# GAP: TempleOS ~/TimeClock/TimeFile.DATA.Z — use host-writable temp file
FILE: con "/tmp/temple-timeclock.txt";

top: ref Toplevel;
isin := 0;

cfg := array[] of {
	"frame .f",
	"label .f.st -text {Status: out}",
	"entry .f.e -width 40",
	"frame .f.b",
	"button .f.b.in -text {Punch In} -command {send cmd in}",
	"button .f.b.out -text {Punch Out} -command {send cmd out}",
	"button .f.b.rep -text {Report} -command {send cmd rep}",
	"pack .f.b.in .f.b.out .f.b.rep -side left -padx 4",
	"text .f.t -width 56 -height 14 -state disabled",
	"pack .f.st -side top -anchor w",
	"pack .f.e -side top -fill x -pady 4",
	"pack .f.b -side top -anchor w",
	"pack .f.t -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
	"bind .f.e <Key-\n> {send cmd in}",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	daytime = load Daytime Daytime->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS TimeClock", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	loadstatus();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		if(s == 16r1b || s == 'q' || s == 'Q')
			exit;
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		case c {
		"in" =>
			punch(1);
		"out" =>
			punch(0);
		"rep" =>
			report();
		}
	}
}

loadstatus()
{
	# last line wins
	fd := sys->open(FILE, Sys->OREAD);
	if(fd == nil){
		isin = 0;
		return;
	}
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return;
	s := string buf[0:n];
	isin = 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || i == 0){
			# look at line starts
			;
		}
	# crude: find last IN/OUT
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		if(len ln >= 3 && ln[0:3] == "IN ")
			isin = 1;
		else if(len ln >= 4 && ln[0:4] == "OUT ")
			isin = 0;
	}
	setstatus();
}

setstatus()
{
	if(isin)
		cmd(top, ".f.st configure -text {Status: IN}");
	else
		cmd(top, ".f.st configure -text {Status: OUT}");
	cmd(top, "update");
}

punch(wantin: int)
{
	if(wantin && isin)
		return;
	if(!wantin && !isin)
		return;
	desc := cmd(top, ".f.e get");
	now := daytime->text(daytime->local(daytime->now()));
	tag := "OUT ";
	if(wantin)
		tag = "IN ";
	line := tag + now + " " + desc + "\n";
	fd := sys->open(FILE, Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(FILE, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "timeclock: %s: %r\n", FILE);
		return;
	}
	# append
	sys->seek(fd, big 0, Sys->SEEKEND);
	b := array of byte line;
	sys->write(fd, b, len b);
	isin = wantin;
	setstatus();
	cmd(top, ".f.e delete 0 end");
	report();
}

report()
{
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	fd := sys->open(FILE, Sys->OREAD);
	if(fd == nil)
		cmd(top, ".f.t insert end {(no entries)}");
	else{
		buf := array[16384] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			cmd(top, ".f.t insert end {"+string buf[0:n]+"}");
	}
	cmd(top, ".f.t configure -state disabled");
	cmd(top, "update");
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "timeclock tk: %s\n", e);
	return e;
}
