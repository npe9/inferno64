implement Digits;

# TempleOS Demo/Games/Digits.HC — Tk stand-in for DolDoc
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

Digits: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

names := array[] of {
	"black", "brown", "red", "orange", "yellow",
	"green", "blue", "violet", "grey", "white"
};
tkcols := array[] of {
	"#000000", "#884400", "#ff0000", "#ff8800", "#ffff00",
	"#00aa00", "#0000ff", "#8800ff", "#888888", "#ffffff"
};

Pintro, Pshow, Pguess, Pok, Pfail: con iota;

top: ref Toplevel;
answer: string;
phase := Pintro;
gi := 0;

cfg := array[] of {
	"frame .f",
	"text .f.t -width 60 -height 16 -bg #444444 -fg white -state disabled",
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
	puts("Memory game — remember the digits (EE color codes).\n\n", nil);
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
		puts("\n\nWrong. Score: "+string len answer+"\n", nil);
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
