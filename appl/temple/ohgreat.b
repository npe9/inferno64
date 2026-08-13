implement Ohgreat;

# TempleOS Demo/Snd/OhGreat.HC — tone->play + Tk lyrics
# GAP: Play() lyric syllables sync is approximate; we show full verse text.

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

Ohgreat: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

top: ref Toplevel;
playing := 0;

# scores from OhGreat.HC (music strings only)
scores := array[] of {
	"6hEqDC5B6CDhE",
	"5GqFEFhG6E",
	"6qDC5B6CDhE5G",
	"5qFEFhGB6qC",
	"6DhCeDC5hBG",
	"5qFEFhG6EqD",
	"6C5B6CDhE5G",
	"5qFEFhG6EqD",
	"6C5B6CDhE5G",
	"5qFEFhG6EqD",
	"6C5B6CDhE5G",
	"5qFEFhGB6qC",
	"6DhCeDC5hBG",
	"5qFEFhG",
};

lyrics :=
	"God is a god of love.\n"+
	"He watches us from above.\n"+
	"Our world isn't always nice.\n"+
	"Before you gripe think twice.\n"+
	"He watches us from above.\n"+
	"He'll smack you without a glove.\n"+
	"Our world isn't always nice.\n";

cfg := array[] of {
	"frame .f",
	"text .f.t -width 48 -height 12 -state disabled",
	"label .f.l -text {space=play/stop · Esc quit}",
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
		sys->fprint(sys->fildes(2), "ohgreat: cannot load tone: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	e := tone->init();
	if(e != nil)
		sys->fprint(sys->fildes(2), "ohgreat: tone: %s\n", e);
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS OhGreat", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t insert end {"+lyrics+"\n(Terry A. Davis)\n}");
	cmd(top, ".f.t configure -state disabled");
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
		if(s == ' '){
			if(playing){
				tone->stop();
				playing = 0;
			}else{
				playing = 1;
				spawn playsong();
			}
		}
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	}
}

playsong()
{
	for(i := 0; i < len scores && playing; i++){
		e := tone->play(scores[i]);
		if(e != nil){
			sys->fprint(sys->fildes(2), "ohgreat: play: %s\n", e);
			break;
		}
	}
	playing = 0;
}

cmd(win: ref Toplevel, s: string): string
{
	return tk->cmd(win, s);
}
