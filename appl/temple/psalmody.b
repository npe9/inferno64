implement Psalmody;

# TempleOS Apps/Psalmody — simplified note-list music editor (Tk + tone.dis)
# GAP: no staff sprites / jukebox / puppets / full Psalmody controls

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

include "math.m";
	math: Math;

include "tone.m";
	tone: Tone;

Psalmody: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Note: adt {
	oct: int;
	name: int;	# 0=C .. 6=B
	dur: int;	# ms
};

top: ref Toplevel;
notes: list of ref Note;
curoct := 4;
curdur := 500;
have_tone := 0;
FILE: con "/tmp/temple-song.txt";

durkeys := " whqes";	# index 1..5

cfg := array[] of {
	"frame .f",
	"label .f.gap -fg #884400 -text {GAP: text roll — no DolDoc staff / jukebox / puppets}",
	"label .f.st -text {oct=4 dur=500ms notes=0}",
	"text .f.t -width 64 -height 16 -state disabled",
	"frame .f.b",
	"button .f.b.play -text Play -command {send cmd play}",
	"button .f.b.save -text Save -command {send cmd save}",
	"button .f.b.load -text Load -command {send cmd load}",
	"button .f.b.clr -text Clear -command {send cmd clear}",
	"button .f.b.quit -text Quit -command {send cmd quit}",
	"pack .f.b.play .f.b.save .f.b.load .f.b.clr .f.b.quit -side left -padx 4",
	"label .f.h -text {0-9 octave · A-G note · space play · w/h/s duration · q quit}",
	"pack .f.gap .f.st .f.t .f.b .f.h -side top -anchor w -pady 2",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	tone = load Tone Tone->PATH;
	math = load Math Math->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	notes = nil;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Psalmody", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	setstatus();
	redraw();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		case s {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
			exit;
		' ' =>
			play();
		'0' to '9' =>
			curoct = s - '0';
			setstatus();
		'A' to 'G' or 'a' to 'g' =>
			addnote(noteidx(s));
		'W' or 'w' =>
			curdur = 2000; setstatus();
		'H' or 'h' =>
			curdur = 1000; setstatus();
		'S' or 's' =>
			curdur = 125; setstatus();
		}
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		case c {
		"play" =>
			play();
		"save" =>
			savefile();
		"load" =>
			loadfile();
		"clear" =>
			notes = nil; redraw();
		"quit" =>
			if(have_tone) tone->stop();
			exit;
		}
	}
}

noteidx(c: int): int
{
	if(c >= 'a')
		c -= 'a' - 'A';
	return c - 'A';
}

notename(n: int): string
{
	names := array[] of { "C", "D", "E", "F", "G", "A", "B" };
	if(n < 0 || n > 6)
		return "?";
	return names[n];
}

durletter(ms: int): string
{
	case ms {
	2000 => return "w";
	1000 => return "h";
	500 => return "q";
	250 => return "e";
	125 => return "s";
	}
	return "q";
}

addnote(n: int)
{
	if(n < 0 || n > 6)
		return;
	notes = ref Note(curoct, n, curdur) :: notes;
	redraw();
	if(have_tone)
		tone->beep(freq(curoct, n), 80);
}

freq(o, n: int): int
{
	semi := array[] of { 0, 2, 4, 5, 7, 9, 11 };
	# A4=440, octave number like tone.play (octave digit then note)
	f := 440.0 * math->pow(2.0, real((o+1)*12 + semi[n] - 69) / 12.0);
	return int f;
}

setstatus()
{
	cmd(top, sys->sprint(".f.st configure -text {oct %d · dur %dms · %d notes}",
		curoct, curdur, listlen(notes)));
}

listlen(l: list of ref Note): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

redraw()
{
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	i := 1;
	for(l := notes; l != nil; l = tl l){
		nt := hd l;
		cmd(top, sys->sprint(".f.t insert end {%d: %s%d %dms}\n",
			i, notename(nt.name), nt.oct, nt.dur));
		i++;
	}
	cmd(top, ".f.t configure -state disabled");
	setstatus();
	cmd(top, "update");
}

mkscore(): string
{
	s := "";
	for(l := notes; l != nil; l = tl l){
		nt := hd l;
		s += sys->sprint("%d%s%s", nt.oct, durletter(nt.dur), notename(nt.name));
	}
	return s;
}

play()
{
	if(!have_tone || notes == nil)
		return;
	sc := mkscore();
	tone->play(sc);
}

savefile()
{
	fd := sys->create(FILE, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "psalmody: %s: %r\n", FILE);
		return;
	}
	for(l := notes; l != nil; l = tl l){
		nt := hd l;
		line := sys->sprint("%d %s %d\n", nt.oct, notename(nt.name), nt.dur);
		b := array of byte line;
		sys->write(fd, b, len b);
	}
}

loadfile()
{
	fd := sys->open(FILE, Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return;
	notes = nil;
	s := string buf[0:n];
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		if(len ln == 0)
			continue;
		(nil, tok) := sys->tokenize(ln, " \t");
		if(tok == nil || tl tok == nil || tl tl tok == nil)
			continue;
		o := int hd tok;
		nm := hd tl tok;
		d := int hd tl tl tok;
		ni := -1;
		for(i := 0; i < 7; i++)
			if(notename(i) == nm){
				ni = i;
				break;
			}
		if(ni < 0)
			continue;
		notes = ref Note(o, ni, d) :: notes;
	}
	# reverse to preserve order
	rev: list of ref Note;
	for(l := notes; l != nil; l = tl l)
		rev = hd l :: rev;
	notes = rev;
	redraw();
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "psalmody tk: %s\n", e);
	return e;
}
