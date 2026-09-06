implement Digits;

# TempleOS Demo/Games/Digits.HC — remember a growing string of digits.
#
# The demonstration is the Define entry: a list of zero-terminated
# strings loaded into the symbol table under one name, printed back with
# the %Z format code.
#
#	"$$FG,%Z$$%d: %Z\n",i,"ST_RAINBOW_10",i,i,"ST_RAINBOW_10";
#
# prints the number in colour i and then names it, both out of the same
# Define entry.  ST_RAINBOW_10 (Adam/Gr/GrPalette.HC) is BLACK, BROWN,
# RED, LTRED, YELLOW, GREEN, BLUE, PURPLE, LTGRAY, WHITE — so the names
# below are TempleOS's, not the resistor code's, even though the text
# says electrical engineering colour codes.  Two Beeps on a wrong digit.
#
# GAP: DolDoc $$FG,%Z colored Define spans → Tk text tags.

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

include "rand.m";
	rand: Rand;

include "math.m";
	math: Math;

include "tone.m";
	tone: Tone;

Digits: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

A4ONA: con 60;			# Ona2Freq: ona 60 is 440Hz

# ST_RAINBOW_10, with the exact TempleOS palette values
names := array[] of {
	"BLACK", "BROWN", "RED", "LTRED", "YELLOW",
	"GREEN", "BLUE", "PURPLE", "LTGRAY", "WHITE"
};
tkcols := array[] of {
	"#000000", "#aa5500", "#aa0000", "#ff5555", "#ffff55",
	"#00aa00", "#0000aa", "#aa00aa", "#aaaaaa", "#ffffff"
};
have_tone := 0;

Pintro, Pshow, Pguess, Pok, Pfail: con iota;

top: ref Toplevel;
answer: string;
phase := Pintro;
gi := 0;

cfg := array[] of {
	"frame .f",
	"text .f.t -width 60 -height 16 -bg #555555 -fg white -state disabled",
	"label .f.l -text {space=advance · type digits to guess · Esc quit}",
	"pack .f.l -side top -fill x",
	"pack .f.t -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	rand = load Rand Rand->PATH;
	math = load Math Math->PATH;
	tone = load Tone Tone->PATH;
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Digits", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	for(i = 0; i < 10; i++)
		cmd(top, sys->sprint(".f.t tag configure d%d -foreground %s", i, tkcols[i]));
	intro();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		key(s);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	}
}

intro()
{
	clear();
	# the original's own text, its two soft spaces between sentences
	puts("\nThis is a memory game.  "+
		"Try to remember the digits and enter them.  "+
		"They are colored based on electrical "+
		"engineering color codes.\n", nil);
	for(i := 0; i < 10; i++){
		puts(string i + ": ", nil);
		puts(names[i] + "\n", "d"+string i);
	}
	puts("\nPress space to start.\n", nil);
	answer = nil;
	phase = Pintro;
}

extend()
{
	answer[len answer] = rn(10) + '0';
	clear();
	puts("Pattern length "+string len answer+"\n\n", nil);
	for(i := 0; i < len answer; i++)
		puts(sys->sprint("%c ", answer[i]), "d"+string(answer[i]-'0'));
	puts("\n\nPress space, then type the digits.\n", nil);
	phase = Pshow;
}

beginguess()
{
	clear();
	puts("Guess length "+string len answer+"\n\n", nil);
	phase = Pguess;
	gi = 0;
}

key(k: int)
{
	if(k == 16r1b || k == 'q' || k == 'Q')
		exit;
	if(k == ' ' || k == '\n'){
		case phase {
		Pintro or Pfail =>
			answer = nil;
			extend();
		Pshow =>
			beginguess();
		Pok =>
			extend();
		}
		return;
	}
	if(phase != Pguess || k < '0' || k > '9')
		return;
	puts(sys->sprint("%c ", k), "d"+string(k-'0'));
	if(k != answer[gi]){
		spawn beeps(2);		# Beep; Beep;
		puts("\n\nScore:"+string len answer+"\n", nil);
		puts("Answer: ", nil);
		for(i := 0; i < len answer; i++)
			puts(sys->sprint("%c ", answer[i]), "d"+string(answer[i]-'0'));
		puts("\nSpace to restart.\n", nil);
		phase = Pfail;
		return;
	}
	gi++;
	if(gi >= len answer){
		puts("\n\nOK — space for longer pattern.\n", nil);
		phase = Pok;
	}
}

clear()
{
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	cmd(top, ".f.t configure -state disabled");
}

puts(s: string, tag: string)
{
	cmd(top, ".f.t configure -state normal");
	if(tag != nil)
		cmd(top, ".f.t insert end {"+s+"} "+tag);
	else
		cmd(top, ".f.t insert end {"+s+"}");
	cmd(top, ".f.t configure -state disabled");
	cmd(top, "update");
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "digits tk: %s\n", e);
	return e;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

# Beep: Snd(62) for 500ms then silence for 200ms, n times
beeps(n: int)
{
	if(!have_tone)
		return;
	for(i := 0; i < n; i++){
		tone->beep(onafreq(62), 500);
		sys->sleep(700);
	}
}

onafreq(ona: int): int
{
	if(math == nil)
		return 494;
	f := int (440.0 * math->pow(2.0, real (ona - A4ONA) / 12.0) + 0.5);
	if(f < 1)
		f = 1;
	return f;
}
