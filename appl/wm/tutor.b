implement Wmtutor;

# Nelson's Dream Machines chapter on CAI (computer-assisted instruction)
# and PLATO: a lesson the student's own answers steer, not a document
# they just read - appl/lib/tutor.b (module/tutor.m) parses the plain-
# text branching-lesson format and judges answers against it; this file
# is just the runtime window: show the current frame's text, take a
# typed answer, judge it, show the feedback and the next frame, track a
# score. Deliberately distinct from this tree's existing static
# !Lessons reading material, which has no judging or branching at all.
#
# usage: wm/tutor [lesson-file]

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

include "tutor.m";
	tutor: Tutor;

Wmtutor: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

window: ref Tk->Toplevel;
lesson: ref Tutor->Lesson;
cur: ref Tutor->Frame;
score, attempts: int;
lessonpath := "/lib/tutor/intro.tt";

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
	tutor = load Tutor Tutor->PATH;
	if(tutor == nil)
		loaderr(Tutor->PATH);
	tutor->init();

	argv = tl argv;
	if(argv != nil)
		lessonpath = hd argv;

	(l, err) := tutor->loadlesson(lessonpath);
	if(l == nil){
		sys->fprint(sys->fildes(2), "tutor: cannot load %s: %s\n", lessonpath, err);
		raise "fail:load";
	}
	lesson = l;
	cur = tutor->findframe(lesson, lesson.start);
	if(cur == nil){
		sys->fprint(sys->fildes(2), "tutor: %s: START frame %q not found\n", lessonpath, lesson.start);
		raise "fail:load";
	}

	tkclient->init();
	buts := Tkclient->Resize | Tkclient->Hide;
	winctl: chan of string;
	title := "Tutor";
	if(lesson.title != "")
		title = lesson.title;
	(window, winctl) = tkclient->toplevel(ctxt, nil, title, buts);
	cmdc := chan of string;
	tk->namechan(window, cmdc, "cmd");
	for(tc := 0; tc < len tkconfig; tc++)
		tkcmd(window, tkconfig[tc]);
	if((e := tkcmd(window, "variable lasterror")) != nil){
		sys->fprint(sys->fildes(2), "tutor: tk initialization failed: %s\n", e);
		raise "fail:tk";
	}
	fittoscreen(window);
	tkcmd(window, "update");

	showtext(cur.text);
	setscore();

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
	"frame .tool",
	"label .tool.score -text {score 0/0} -anchor w",
	"pack .tool.score -side left -expand 1 -fill x",

	"frame .view",
	"text .view.t -state disabled -bd 0 -width 0 -height 0 -bg white -wrap word -yscrollcommand {.view.yscroll set}",
	"scrollbar .view.yscroll -orient vertical -command {.view.t yview}",
	"pack .view.yscroll -side left -fill y",
	"pack .view.t -expand 1 -fill both",

	"frame .answer",
	"label .answer.l -text {your answer:}",
	"entry .answer.e -bg white",
	"button .answer.submit -text Submit -command {send cmd submit}",
	"pack .answer.l -side left",
	"pack .answer.e -side left -expand 1 -fill x -padx 4",
	"pack .answer.submit -side left",

	"bind .answer.e <Key-\n> {send cmd submit}",
	"bind .view.t <Button-1> +{grab set .view.t}",
	"bind .view.t <ButtonRelease-1> +{grab release .view.t}",

	"pack .tool -fill x",
	"pack .view -expand 1 -fill both",
	"pack .answer -fill x",
	"pack propagate . 0",
	". configure -width 640 -height 420",
	"focus .answer.e",
};

docmd(s: string)
{
	case s {
	"submit" =>
		answer := tkcmd(window, ".answer.e get");
		if(answer == "")
			return;
		(correct, next, response) := tutor->judge(cur, answer);
		attempts++;
		if(correct)
			score++;
		setscore();
		nf := tutor->findframe(lesson, next);
		if(nf == nil){
			showtext(response + "\n\n[end of lesson - no frame named " + next + "]");
			return;
		}
		cur = nf;
		showtext(response + "\n\n" + cur.text);
		tkcmd(window, ".answer.e delete 0 end");
	}
}

showtext(s: string)
{
	tkcmd(window, ".view.t delete 1.0 end");
	tkcmd(window, ".view.t insert 1.0 " + tk->quote(s));
}

setscore()
{
	tkcmd(window, ".tool.score configure -text " + tk->quote(sys->sprint("score %d/%d", score, attempts)));
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
