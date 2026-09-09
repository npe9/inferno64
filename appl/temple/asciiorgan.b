implement Asciiorgan;

# TempleOS Demo/Snd/ASCIIOrgan.HC — ASCII chart + sustained-tone organ.
# Original: each GetChar() does Snd(ch-CH_ESC) — Snd takes an ona (semitone,
# freq = 440*2^((ona-60)/12)) and HOLDS the tone until the next call; Esc
# silences (Snd; = ona 0 = off) and exits.  Chart chars print in RED, the
# <SHIFT-ESC> prompt in GREEN, and a clickable "Click for better organ"
# sprite links to Apps/Psalmody.

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

Asciiorgan: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Command: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

CHESC: con 16r1b;	# TempleOS CH_ESC
A4ONA: con 60;		# TempleOS Ona2Freq: ona 60 = A4 = 440Hz, ona 0 = off

top: ref Toplevel;
have_tone := 0;

FN: con "/fonts/lucida/unicode.8.font";

cfg := array[] of {
	"image create bitmap organ -file /icons/temple/asciiorgan_1.bit -maskfile /icons/temple/asciiorgan_1.mask",
	"frame .f -bg white",
	"text .f.t -width 32 -height 37 -state disabled -font " + FN + " -bg white -fg black",
	"frame .f.b -bg white",
	"button .f.b.organ -image organ -command {send cmd organ}",
	"label .f.b.cap -text {Click for better organ} -font " + FN + " -bg white -fg black",
	".f.t tag configure red -foreground #AA0000",
	".f.t tag configure green -foreground #00AA00",
	"pack .f.b.organ -side left -padx 4 -pady 2",
	"pack .f.b.cap -side left -padx 4",
	"pack .f.b -side bottom -fill x",
	"pack .f.t -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	math = load Math Math->PATH;
	if(tk == nil || tkclient == nil || math == nil){
		sys->fprint(sys->fildes(2), "asciiorgan: cannot load modules: %r\n");
		raise "fail:load";
	}
	tone = load Tone Tone->PATH;
	if(tone != nil){
		have_tone = 1;
		e := tone->init();
		if(e != nil)
			sys->fprint(sys->fildes(2), "asciiorgan: tone init: %s (organ may be silent)\n", e);
	}else
		sys->fprint(sys->fildes(2), "asciiorgan: cannot load tone: %r (silent)\n");
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS ASCIIOrgan", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	fillchart();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		# TempleOS: Snd(ch-CH_ESC) on EVERY key, then check for exit —
		# each keypress re-pitches a continuous drone; Esc gives ona 0 (off).
		if(have_tone && s >= 0 && s < 256){
			ona := s - CHESC;
			if(ona <= 0)
				tone->stop();
			else
				tone->snd(onafreq(ona));
		}
		if(s == CHESC){
			if(have_tone)
				tone->stop();
			exit;
		}
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	<-cmdch =>
		psalmody(ctxt);
	}
}

# TempleOS Snd(ona): freq = 440*2^((ona-60)/12), rounded
onafreq(ona: int): int
{
	f := int (440.0 * math->pow(2.0, real (ona - A4ONA) / 12.0) + 0.5);
	if(f < 1)
		f = 1;
	return f;
}

fillchart()
{
	cmd(top, ".f.t delete 1.0 end");
	chart := "";
	for(i := 0; i < 32; i++)
		chart += cell(i) + cell(i+32) + cell(i+64) + cell(i+96) + "\n";
	cmd(top, ".f.t insert end '" + chart);
	# characters print in RED: cell k's char is column 5k+3 of each line
	for(i = 0; i < 32; i++){
		l := string (i + 1);
		for(k := 0; k < 4; k++){
			c := 5*k + 3;
			cmd(top, ".f.t tag add red " + l + "." + string c +
				" " + l + "." + string (c+1));
		}
	}
	cmd(top, ".f.t insert end '\nPress keys to make snds\nand press ");
	cmd(top, ".f.t insert end {<SHIFT-ESC>} green");
	cmd(top, ".f.t insert end '" + " to exit.\n");
}

# SafePutChar: "%02X $$RED$$%c$$FG$$ " for printables, hex + blank otherwise
cell(ch: int): string
{
	if(ch >= 32 && ch < 127)
		return sys->sprint("%02X %c ", ch, ch);
	return sys->sprint("%02X   ", ch);
}

# Sprite "<1>": Click for better organ — #include "::/Apps/Psalmody/Run"
psalmody(ctxt: ref Context)
{
	c := load Command "/dis/temple/psalmody.dis";
	if(c == nil){
		sys->fprint(sys->fildes(2), "asciiorgan: cannot load psalmody: %r\n");
		return;
	}
	spawn c->init(ctxt, "psalmody" :: nil);
}

cmd(t: ref Toplevel, s: string)
{
	e := tk->cmd(t, s);
	if(e != nil && e != "" && e[0] == '!')
		sys->fprint(sys->fildes(2), "asciiorgan: tk %s: %s\n", s, e);
}
