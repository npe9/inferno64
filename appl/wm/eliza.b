implement Wmeliza;

# Nelson's Dream Machines chapter on AI singles out Weizenbaum's ELIZA -
# appl/lib/eliza.b (module/eliza.m) is the actual keyword-ranked pattern
# matcher and pronoun-reflection engine; this file is just the chat
# window: show the transcript so far, take a typed line, get a reply,
# append both to the transcript, scroll to the end. Unlike wm/tutor.b
# (which replaces its view each turn - a lesson frame is a fresh page),
# this view only ever grows - a conversation is its own scrollback.
#
# usage: wm/eliza [script-file]

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "wmclient.m";
	wmclient: Wmclient;

include "eliza.m";
	eliza: Eliza;

Wmeliza: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

window: ref Tk->Toplevel;
script: ref Eliza->Script;
scriptpath := "/lib/eliza/doctor.el";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->NEWPGRP, nil);

	draw = load Draw Draw->PATH;
	if(draw == nil)
		loaderr("Draw");
	tk = load Tk Tk->PATH;
	if(tk == nil)
		loaderr(Tk->PATH);
	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		loaderr(Tkclient->PATH);
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		loaderr(Wmclient->PATH);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	eliza = load Eliza Eliza->PATH;
	if(eliza == nil)
		loaderr(Eliza->PATH);
	eliza->init();

	argv = tl argv;
	if(argv != nil)
		scriptpath = hd argv;

	(scr, err) := eliza->loadscript(scriptpath);
	if(scr == nil){
		sys->fprint(sys->fildes(2), "eliza: cannot load %s: %s\n", scriptpath, err);
		raise "fail:load";
	}
	script = scr;

	tkclient->init();
	buts := Tkclient->Resize | Tkclient->Hide;
	winctl: chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Eliza", buts);
	cmdc := chan of string;
	tk->namechan(window, cmdc, "cmd");
	for(tc := 0; tc < len tkconfig; tc++)
		tkcmd(window, tkconfig[tc]);
	if((e := tkcmd(window, "variable lasterror")) != nil){
		sys->fprint(sys->fildes(2), "eliza: tk initialization failed: %s\n", e);
		raise "fail:tk";
	}
	fittoscreen(window);
	tkcmd(window, "update");

	if(script.greeting != "")
		appendline("Eliza: " + script.greeting);

	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd"::"ptr"::nil);

	for(;;) alt {
	s := <-window.ctxt.kbd =>
		tk->keyboard(window, s);
	s := <-window.ctxt.ptr =>
		tk->pointer(window, *s);
	s := <-window.ctxt.ctl or
	s = <-window.wreq or
	s = <-winctl =>
		werr := tkclient->wmctl(window, s);
		if(werr == nil && s[0] == '!')
			tkcmd(window, "update");
	s := <-cmdc =>
		docmd(s);
	}
}

tkconfig := array[] of {
	"frame .view",
	"text .view.t -state disabled -bd 0 -width 0 -height 0 -bg white -wrap word -yscrollcommand {.view.yscroll set}",
	"scrollbar .view.yscroll -orient vertical -command {.view.t yview}",
	"pack .view.yscroll -side left -fill y",
	"pack .view.t -expand 1 -fill both",

	"frame .answer",
	"label .answer.l -text {you:}",
	"entry .answer.e -bg white",
	"button .answer.submit -text Send -command {send cmd submit}",
	"pack .answer.l -side left",
	"pack .answer.e -side left -expand 1 -fill x -padx 4",
	"pack .answer.submit -side left",

	"bind .answer.e <Key-\n> {send cmd submit}",
	"bind .view.t <Button-1> +{grab set .view.t}",
	"bind .view.t <ButtonRelease-1> +{grab release .view.t}",

	"pack .view -expand 1 -fill both",
	"pack .answer -fill x",
	"pack propagate . 0",
	". configure -width 560 -height 420",
	"focus .answer.e",
};

docmd(s: string)
{
	case s {
	"submit" =>
		line := tkcmd(window, ".answer.e get");
		if(line == "")
			return;
		appendline("You: " + line);
		reply := eliza->respond(script, line);
		appendline("Eliza: " + reply);
		tkcmd(window, ".answer.e delete 0 end");
	}
}

appendline(s: string)
{
	tkcmd(window, ".view.t configure -state normal");
	tkcmd(window, ".view.t insert end " + tk->quote(s + "\n\n"));
	tkcmd(window, ".view.t configure -state disabled");
	tkcmd(window, ".view.t see end");
}

loaderr(modname: string)
{
	sys->print("cannot load %s module: %r\n", modname);
	raise "fail:init";
}

fittoscreen(win: ref Tk->Toplevel)
{
	Point, Rect: import draw;
	if(win.image == nil || win.image.screen == nil)
		return;
	r := win.image.screen.image.r;
	scrsize := Point((r.max.x - r.min.x), (r.max.y - r.min.y));
	bd := int tkcmd(win, ". cget -bd");
	winsize := Point(int tkcmd(win, ". cget -actwidth") + bd * 2, int tkcmd(win, ". cget -actheight") + bd * 2);
	if(winsize.x > scrsize.x)
		tkcmd(win, ". configure -width " + string (scrsize.x - bd * 2));
	if(winsize.y > scrsize.y)
		tkcmd(win, ". configure -height " + string (scrsize.y - bd * 2));
	actr: Rect;
	actr.min = Point(int tkcmd(win, ". cget -actx"), int tkcmd(win, ". cget -acty"));
	actr.max = actr.min.add((int tkcmd(win, ". cget -actwidth") + bd*2,
				int tkcmd(win, ". cget -actheight") + bd*2));
	(dx, dy) := (actr.dx(), actr.dy());
	if(actr.max.x > r.max.x)
		(actr.min.x, actr.max.x) = (r.max.x - dx, r.max.x);
	if(actr.max.y > r.max.y)
		(actr.min.y, actr.max.y) = (r.max.y - dy, r.max.y);
	if(actr.min.x < r.min.x)
		(actr.min.x, actr.max.x) = (r.min.x, r.min.x + dx);
	if(actr.min.y < r.min.y)
		(actr.min.y, actr.max.y) = (r.min.y, r.min.y + dy);
	tkcmd(win, ". configure -x " + string actr.min.x + " -y " + string actr.min.y);
}

tkcmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		sys->print("tk error %s on '%s'\n", e, s);
	return e;
}
