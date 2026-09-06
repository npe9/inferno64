implement Timeclock;

# TempleOS Apps/TimeClock — punch clock with weekly totals (TimeRep)
#
# GAP: DolDoc terminal → Tk window stand-in; $$BK,1$$ blink approximated by a
#      foreground-color toggle on the warning text.
# GAP: original stores binary CDate records, compressed, in
#      ~/TimeClock/TimeFile.DATA.Z; we store one text record per line
#      (uncompressed) in /usr/$user/timeclock/timefile.
# GAP: in the GUI the description is typed (multi-line Tk text box) before
#      punching rather than in the original's modal GetStr prompt after the
#      punch; the command-line mode prompts after the punch like the original,
#      but the description ends on a lone '.' line instead of <ESC>.
# BUG: end-of-file does not end the description.  readdesc() below stops when
#      sys->read returns <= 0, which is correct, but on a host-redirected
#      stdin under emu that read never returns 0 at EOF -- it blocks.
#      Measured both ways: `printf 'x\n.\n' | emu -r. temple/timeclock out`
#      exits 0 and writes the record, `printf 'x\n' | ...` hangs until killed,
#      the same under emu-g and emu-cocoa.  Give the description as arguments,
#      or end it with a dot.

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
	Tm: import daytime;

Timeclock: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# TET_PUNCH_IN / TET_PUNCH_OUT record (original TimeEntry: type + CDate + desc)
Entry: adt {
	isin:	int;		# 1 = punch in, 0 = punch out
	secs:	int;		# epoch seconds (daytime->now())
	desc:	string;
};

file: string;			# TIME_FILENAME equivalent
entries: list of ref Entry;	# chronological order
top: ref Toplevel;
isin := 0;
warned := 0;
bkon := 0;

# TempleOS month start tables (Kernel/KDate.HC)
monstart1 := array[] of {0,31,59,90,120,151,181,212,243,273,304,334};
monstart2 := array[] of {0,31,60,91,121,152,182,213,244,274,305,335};

cfg := array[] of {
	"frame .f",
	"label .f.st -text {Status: OUT}",
	"label .f.dl -text {Description:}",
	"text .f.e -width 56 -height 3",
	"frame .f.b",
	"button .f.b.in -text {Punch In} -command {send cmd in}",
	"button .f.b.out -text {Punch Out} -command {send cmd out}",
	"button .f.b.rep -text {Report} -command {send cmd rep}",
	"pack .f.b.in .f.b.out .f.b.rep -side left -padx 4",
	"text .f.t -width 56 -height 16 -background #FFFFFF -foreground #000000 -state disabled",
	".f.t tag configure red -foreground #AA0000",	# $$RED$$
	".f.t tag configure bk -foreground #000000",	# $$BK,1$$ (blinker toggles)
	"pack .f.st -side top -anchor w",
	"pack .f.dl -side top -anchor w",
	"pack .f.e -side top -fill x -pady 4",
	"pack .f.b -side top -anchor w",
	"pack .f.t -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
	"focus .f.e",
};

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	daytime = load Daytime Daytime->PATH;
	if(daytime == nil){
		sys->fprint(sys->fildes(2), "timeclock: cannot load %s: %r\n", Daytime->PATH);
		return;
	}

	# public PunchIn; PunchOut; TimeRep; were shell commands in TempleOS
	if(argv != nil)
		argv = tl argv;
	if(argv != nil){
		clirun(argv);
		return;
	}

	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
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

	initfile(0);
	loadentries();
	showreport(0);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	# DolDoc $$BK,1$$ blink
	tick := chan of int;
	spawn blinker(tick);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		if(s == 16r1b)		# Esc quits ('q' must stay typable in the description)
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
			showreport(0);
		}
	<-tick =>
		blinkstep();
	}
}

blinker(c: chan of int)
{
	for(;;){
		sys->sleep(250);
		c <-= 1;
	}
}

blinkstep()
{
	if(!warned)
		return;
	bkon ^= 1;
	if(bkon)
		cmd(top, ".f.t tag configure bk -foreground #FFFFFF");
	else
		cmd(top, ".f.t tag configure bk -foreground #000000");
	cmd(top, "update");
}

# ~/TimeClock (Install.HC's DirMk) → /usr/$user/timeclock; /tmp fallback
initfile(verbose: int)
{
	u := username();
	dir := "/usr/" + u + "/timeclock";
	(ok, nil) := sys->stat(dir);
	if(ok < 0){
		fd := sys->create(dir, Sys->OREAD, Sys->DMDIR|8r755);
		if(fd == nil){
			file = "/tmp/temple-timeclock.txt";
			return;
		}
		if(verbose)
			sys->print("Type 'timeclock in', 'timeclock out' or 'timeclock rep'.\n");
	}
	file = dir + "/timefile";
}

username(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd != nil){
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			return string buf[0:n];
	}
	return "inferno";
}

readall(fd: ref Sys->FD): string
{
	data := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		nd := array[len data + n] of byte;
		nd[0:] = data;
		nd[len data:] = buf[0:n];
		data = nd;
	}
	return string data;
}

# record line: IN|OUT <epoch secs> <desc with \ and newline escaped>
escape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'\\' =>	r += "\\\\";
		'\n' =>	r += "\\n";
		* =>	r[len r] = s[i];
		}
	return r;
}

unescape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		if(s[i] == '\\' && i+1 < len s){
			i++;
			if(s[i] == 'n')
				r[len r] = '\n';
			else
				r[len r] = s[i];
		} else
			r[len r] = s[i];
	}
	return r;
}

parseline(ln: string): ref Entry
{
	i := 0;
	while(i < len ln && ln[i] != ' ')
		i++;
	if(i >= len ln)
		return nil;
	pin: int;
	case ln[0:i] {
	"IN" =>		pin = 1;
	"OUT" =>	pin = 0;
	* =>		return nil;
	}
	j := i + 1;
	while(j < len ln && ln[j] != ' ')
		j++;
	secstr := ln[i+1:j];
	secs := int secstr;
	if(secs == 0 && secstr != "0")
		return nil;
	desc := "";
	if(j < len ln)
		desc = unescape(ln[j+1:]);
	return ref Entry(pin, secs, desc);
}

loadentries()
{
	entries = nil;
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		return;
	(nil, lines) := sys->tokenize(readall(fd), "\n");
	el: list of ref Entry = nil;
	for(; lines != nil; lines = tl lines){
		e := parseline(hd lines);
		if(e != nil)
			el = e :: el;
	}
	entries = revl(el);
}

revl(l: list of ref Entry): list of ref Entry
{
	r: list of ref Entry = nil;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

writeentry(e: ref Entry): int
{
	fd := sys->open(file, Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(file, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	sys->seek(fd, big 0, Sys->SEEKEND);
	tag := "OUT";
	if(e.isin)
		tag = "IN";
	b := array of byte (tag + " " + string e.secs + " " + escape(e.desc) + "\n");
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

# TempleOS YearStartDate: 32-bit day since AD 0, given year (Kernel/KDate.HC)
yearstartdate(y: int): int
{
	y1 := y - 1;
	return y*365 + y1/4 - y1/100 + y1/400 - y1/4000;
}

# CDate .date (days since AD 0) of a local Tm; week = tosday/7 as in TimeRep
tosday(tm: ref Tm): int
{
	y := tm.year + 1900;
	i1 := yearstartdate(y);
	d: int;
	if(yearstartdate(y+1) - i1 == 365)
		d = monstart1[tm.mon];
	else
		d = monstart2[tm.mon];
	return i1 + d + tm.mday - 1;
}

# MPrintDate: "%02d/%02d/%02d" mon/day/year%100
datefmt(tm: ref Tm): string
{
	return sys->sprint("%02d/%02d/%02d", tm.mon+1, tm.mday, (tm.year+1900)%100);
}

# MPrintTime: "%02d:%02d:%02d"
timefmt(tm: ref Tm): string
{
	return sys->sprint("%02d:%02d:%02d", tm.hour, tm.min, tm.sec);
}

# Week totals as HH:MM:SS.  The original prints them through %T, which shows
# only the time-of-day part of a CDate, so a 40-hour week wrapped to 16:00:00
# on TempleOS; we let the hours field run past 24 so the total stays honest.
durfmt(secs: int): string
{
	sign := "";
	if(secs < 0){
		sign = "-";
		secs = -secs;
	}
	return sys->sprint("%s%02d:%02d:%02d", sign, secs/3600, (secs/60)%60, secs%60);
}

# TimeRep: walk the queue, group by week (date/7), accumulate
# week_total -= in-time, += out-time, += Now if still punched in.
# Returns (is_in, report segments as (text, tk tag)).
timerep(): (int, list of (string, string))
{
	is_in := 0;
	first := 1;
	curweek := -1;
	weektotal := 0;
	segs: list of (string, string) = nil;
	for(l := entries; l != nil; l = tl l){
		e := hd l;
		tm := daytime->local(e.secs);
		week := tosday(tm) / 7;
		if(week != curweek){
			if(!first){
				if(is_in)
					weektotal += daytime->now();
				segs = ("Week Total:" + durfmt(weektotal) + "\n", "") :: segs;
			} else
				first = 0;
			curweek = week;
			weektotal = 0;
		}
		tag := "OUT";
		if(e.isin){
			tag = "IN ";
			if(!is_in)
				weektotal -= e.secs;
			is_in = 1;
		} else {
			if(is_in)
				weektotal += e.secs;
			is_in = 0;
		}
		# "$$RED$$IN " " %D %T:$$FG$$\n%s\n"
		segs = (tag + " " + datefmt(tm) + " " + timefmt(tm) + ":", "red") :: segs;
		segs = ("\n" + e.desc + "\n", "") :: segs;
	}
	if(is_in)
		weektotal += daytime->now();
	segs = ("Week Total:" + durfmt(weektotal) + "\n", "red") :: segs;
	r: list of (string, string) = nil;
	for(; segs != nil; segs = tl segs)
		r = hd segs :: r;
	return (is_in, r);
}

setstatus()
{
	if(isin)
		cmd(top, ".f.st configure -text {Status: IN}");
	else
		cmd(top, ".f.st configure -text {Status: OUT}");
}

showreport(warn: int)
{
	(nowin, segs) := timerep();
	isin = nowin;
	setstatus();
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	for(; segs != nil; segs = tl segs){
		(txt, tg) := hd segs;
		if(tg != "")
			cmd(top, ".f.t insert end " + tk->quote(txt) + " {" + tg + "}");
		else
			cmd(top, ".f.t insert end " + tk->quote(txt));
	}
	if(warn){
		w := "Already Punched-Out\n";
		if(isin)
			w = "Already Punched-In\n";
		cmd(top, ".f.t insert end " + tk->quote(w) + " {bk}");
		warned = 1;
	} else {
		warned = 0;
		bkon = 0;
		cmd(top, ".f.t tag configure bk -foreground #000000");
	}
	cmd(top, ".f.t configure -state disabled");
	cmd(top, ".f.t see end");
	cmd(top, "update");
}

punch(wantin: int)
{
	# PunchIn/PunchOut always run TimeRep first, then warn on a double punch
	if(wantin == isin){
		showreport(1);
		return;
	}
	desc := cmd(top, ".f.e get 1.0 end");
	if(len desc > 0 && desc[0] == '!')
		desc = "";
	while(len desc > 0 && (desc[len desc-1] == '\n' || desc[len desc-1] == ' ' || desc[len desc-1] == '\t'))
		desc = desc[0:len desc-1];
	e := ref Entry(wantin, daytime->now(), desc);
	if(writeentry(e) < 0){
		sys->fprint(sys->fildes(2), "timeclock: %s: %r\n", file);
		return;
	}
	entries = revl(e :: revl(entries));
	cmd(top, ".f.e delete 1.0 end");
	showreport(0);
}

# command-line PunchIn; PunchOut; TimeRep;
clirun(args: list of string)
{
	initfile(1);
	loadentries();
	case hd args {
	"in" or "punchin" =>
		clipunch(1, tl args);
	"out" or "punchout" =>
		clipunch(0, tl args);
	"rep" or "report" or "timerep" =>
		cliprint();
	* =>
		sys->fprint(sys->fildes(2), "usage: timeclock [in|out|rep [description ...]]\n");
	}
}

cliprint(): int
{
	(is_in, segs) := timerep();
	for(; segs != nil; segs = tl segs){
		(txt, nil) := hd segs;
		sys->print("%s", txt);
	}
	return is_in;
}

clipunch(wantin: int, rest: list of string)
{
	is_in := cliprint();
	if(wantin == is_in){
		if(is_in)
			sys->print("Already Punched-In\n");
		else
			sys->print("Already Punched-Out\n");
		return;
	}
	desc := "";
	if(rest != nil){
		for(; rest != nil; rest = tl rest){
			if(desc != "")
				desc += " ";
			desc += hd rest;
		}
	} else {
		# "Enter Description. Press <ESC> when done." (GetStr GSF_WITH_NEW_LINE)
		sys->print("\nEnter Description.\nEnd with EOF (Ctrl-D) or a line containing only '.'\n");
		desc = readdesc();
	}
	e := ref Entry(wantin, daytime->now(), desc);
	if(writeentry(e) < 0)
		sys->fprint(sys->fildes(2), "timeclock: cannot write %s: %r\n", file);
	else
		entries = revl(e :: revl(entries));
}

readdesc(): string
{
	s := "";
	buf := array[512] of byte;
	for(;;){
		n := sys->read(sys->fildes(0), buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
		if(len s >= 2 && s[len s-1] == '\n'){
			i := len s - 2;
			while(i >= 0 && s[i] != '\n')
				i--;
			if(s[i+1:len s-1] == "."){
				s = s[0:i+1];
				break;
			}
		}
	}
	while(len s > 0 && s[len s-1] == '\n')
		s = s[0:len s-1];
	return s;
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "timeclock tk: %s: %s\n", s, e);
	return e;
}
