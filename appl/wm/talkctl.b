implement WmTalkctl;

#
# A floating control for a narrated talk (see lib/demo/*.sh, session(2)) -
# pause it, resume it, or change its pace, without touching the window it
# is narrating.
#
# It has nothing to do with the talk directly: it only writes "speed
# paused\n" to /tmp/talk-ctl, and session(2)'s own `wait` action - the
# thing that actually paces a talk - reads that file back, in Tick-sized
# slices, each time it waits. No file, or one this has never written to,
# means speed 1 and not paused: a talk with no control running is a talk
# that runs exactly as it always did.
#
# What this does NOT reach: `say -t` itself. Narration is a separate
# process that blocks the talk until the line is spoken, and there is no
# way from outside to slow down or pause a voice mid-utterance - the
# neural voice has no speed control at all, and speak(1)'s trick of
# abandoning a line only applies to /dev/voice/screen. Pause here takes
# effect at the next wait, which in the worst case is one utterance's
# length away; that is a real limit, not a bug, and it is why this is
# named a control for the talk's PACING and not for the talk.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tk.m";
	tk: Tk;

include	"tkclient.m";
	tkclient: Tkclient;

WmTalkctl: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

t: ref Tk->Toplevel;
cmd: chan of string;

speed := 1.0;
paused := 0;

Ctlfile: con "/tmp/talk-ctl";

# fewer, bigger steps than a slider: press Faster a few times to skip
# ahead, Slower a few times to hear it more slowly, Reset to give up
# and go back to normal pace.
speeds := array[] of {0.25, 0.5, 1.0, 2.0, 4.0, 8.0};

ctl_cfg := array[] of {
	"frame .f",
	"button .f.pause -text Pause -command {send cmd pause}",
	"button .f.slower -text Slower -command {send cmd slower}",
	"button .f.faster -text Faster -command {send cmd faster}",
	"pack .f.pause .f.slower .f.faster -side left -fill x -expand 1",

	"label .l -label {1.0x}",

	"bind . <Key-p> {send cmd pause}",
	"bind . <Key-space> {send cmd pause}",
	"bind . <Key-s> {send cmd slower}",
	"bind . <Key-f> {send cmd faster}",
	"bind . <Key-r> {send cmd reset}",

	"pack .Wm_t -fill x",
	"pack .f .l",
	"pack propagate . 0",
	"update",
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "talkctl: no window context\n");
		raise "fail:bad context";
	}
	draw := load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(draw == nil || tk == nil || tkclient == nil){
		sys->fprint(sys->fildes(2), "talkctl: couldn't load modules\n");
		return;
	}

	tkclient->init();
	menubut := chan of string;
	(t, menubut) = tkclient->toplevel(ctxt, "-borderwidth 2 -relief raised", "Talk", Tkclient->Appl);

	cmd = chan of string;
	tk->namechan(t, cmd, "cmd");
	for(i := 0; i < len ctl_cfg; i++)
		tk->cmd(t, ctl_cfg[i]);
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);

	writectl();

	for(;;) alt{
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or
	s = <-t.wreq =>
		tkclient->wmctl(t, s);
	menu := <-menubut =>
		if(menu == "exit")
			return;
		tkclient->wmctl(t, menu);
	c := <-cmd =>
		case c {
		"pause" =>
			paused = !paused;
			if(paused)
				tk->cmd(t, ".f.pause configure -text Resume");
			else
				tk->cmd(t, ".f.pause configure -text Pause");
		"slower" =>
			speed = step(speed, -1);
		"faster" =>
			speed = step(speed, 1);
		"reset" =>
			speed = 1.0;
			paused = 0;
			tk->cmd(t, ".f.pause configure -text Pause");
		}
		tk->cmd(t, ".l configure -label {"+speedlabel()+"};update");
		writectl();
	}
}

step(v: real, dir: int): real
{
	best := 0;
	for(i := 0; i < len speeds; i++)
		if(speeds[i] == v)
			best = i;
	best += dir;
	if(best < 0)
		best = 0;
	if(best >= len speeds)
		best = len speeds - 1;
	return speeds[best];
}

speedlabel(): string
{
	if(paused)
		return "paused";
	return sys->sprint("%.2gx", speed);
}

writectl()
{
	fd := sys->create(Ctlfile, Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	sys->fprint(fd, "%g %d\n", speed, paused);
}
