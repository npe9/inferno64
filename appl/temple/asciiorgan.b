implement Asciiorgan;

# TempleOS Demo/Snd/ASCIIOrgan.HC — Tk chart + /dis/lib/tone.dis
# Type keys to beep; Esc/q quit
# DolDoc $$FG chart → Tk text (gap: no colored spans / sprite link to Psalmody)

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

include "tone.m";
	tone: Tone;

Asciiorgan: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

top: ref Toplevel;

cfg := array[] of {
	"frame .f",
	"text .f.t -width 72 -height 18 -state disabled -font /fonts/lucida/unicode.7.font",
	"label .f.l -text {type keys for tones · Esc/q quit}",
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
	tone = load Tone Tone->PATH;
	if(tone == nil){
		sys->fprint(sys->fildes(2), "asciiorgan: cannot load tone: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	e := tone->init();
	if(e != nil)
		sys->fprint(sys->fildes(2), "asciiorgan: tone init: %s (beeps may be silent)\n", e);
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS ASCIIOrgan", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	fillchart();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		if(s == 16r1b || s == 'q' || s == 'Q'){
			tone->stop();
			exit;
		}
		# TempleOS Snd(ch - CH_ESC)
		freq := (s - 16r1b) * 8;
		if(freq < 40)
			freq = 40 + (s & 127) * 4;
		if(freq > 4000)
			freq = 4000;
		tone->beep(freq, 100);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	}
}

fillchart()
{
	cmd(top, ".f.t delete 1.0 end");
	for(i := 0; i < 32; i++){
		line := sys->sprint("%02X %c  %02X %c  %02X %c  %02X %c\n",
			i, safe(i), i+32, safe(i+32), i+64, safe(i+64), i+96, safe(i+96));
		cmd(top, ".f.t insert end {" + line + "}");
	}
}

safe(ch: int): int
{
	if(ch >= 32 && ch < 127 && ch != '{' && ch != '}' && ch != '\\')
		return ch;
	return '.';
}

cmd(t: ref Toplevel, s: string)
{
	e := tk->cmd(t, s);
	if(e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "asciiorgan: tk %s: %s\n", s, e);
}
