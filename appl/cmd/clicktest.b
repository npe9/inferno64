implement Command;

#
# Does a scripted click actually work a widget?
#
# session(2) delivers clicks through /dev/pointerin, and that they arrive has
# been checked at the device: inputtest(1) reads them back off /dev/pointer
# with the right coordinates and the right times. That is not the same as a
# button being pressed. Everything between - the pointer queue, wm, Tk's event
# dispatch, the widget's own hit testing - is untested by that, and this tree
# already has a warning about the general area: synthetic clicks posted at the
# host with CGEvent do not work Tk buttons on this platform, silently.
#
# /dev/pointerin goes in underneath the host, so it may well work where that
# does not. This exists to find out rather than assume, so it reports what a
# click did rather than whether a window looks right.
#
# It puts a button on the screen, writes down where the button actually is,
# and records what reaches it. A script reads the position, clicks there, and
# reads the result. Nothing depends on a screenshot.
#
include "sys.m";
	sys: Sys;
	sprint, fprint: import sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "arg.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

cfg := array[] of {
	"frame .f",
	"button .b -text {press me} -command {send cmd press}",
	"label .l -text {nothing yet}",
	"pack .b .l -in .f",
	"pack .f -fill both -expand 1",
	"pack propagate . 0",
	"update",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(tk == nil || tkclient == nil || arg == nil){
		sys->print("clicktest: load: %r\n");
		raise "fail:load";
	}

	where := "/clicktest.where";
	result := "/clicktest.result";
	wait := 30;
	arg->init(argv);
	arg->setusage("clicktest [-w wherefile] [-r resultfile] [-t seconds]");
	while((o := arg->opt()) != 0)
		case o {
		'w' =>	where = arg->earg();
		'r' =>	result = arg->earg();
		't' =>	wait = int arg->earg();
		* =>	arg->usage();
		}

	if(ctxt == nil){
		fprint(sys->fildes(2), "clicktest: no window context\n");
		raise "fail:context";
	}

	tkclient->init();
	(t, menubut) := tkclient->toplevel(ctxt, "", "clicktest", 0);
	for(i := 0; i < len cfg; i++)
		tk->cmd(t, cfg[i]);

	cmd := chan of string;
	tk->namechan(t, cmd, "cmd");
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);
	tk->cmd(t, "update");

	# Where the button really is, in screen coordinates, which is the only
	# thing a script can act on. -actx and -acty are the position Tk gave
	# the widget after packing; the toplevel's own position has to be added
	# because a widget's is relative to it.
	bx := int tk->cmd(t, ".b cget -actx");
	by := int tk->cmd(t, ".b cget -acty");
	bw := int tk->cmd(t, ".b cget -actwidth");
	bh := int tk->cmd(t, ".b cget -actheight");
	tx := int tk->cmd(t, ". cget -actx");
	ty := int tk->cmd(t, ". cget -acty");
	(cx, cy) := (tx + bx + bw/2, ty + by + bh/2);

	wfd := sys->create(where, Sys->OWRITE, 8r666);
	if(wfd == nil){
		fprint(sys->fildes(2), "clicktest: %s: %r\n", where);
		raise "fail:create";
	}
	fprint(wfd, "%d %d\n", cx, cy);
	wfd = nil;
	sys->print("clicktest: the button's centre is at %d %d\n", cx, cy);

	stop := chan of int;
	spawn tkclient->handler(t, stop);
	spawn timeout(wait, cmd);

	n := 0;
	rfd := sys->create(result, Sys->OWRITE, 8r666);
	for(;;)alt{
	c := <-cmd =>
		if(c == "timeout")
			break;
		n++;
		tk->cmd(t, ".l configure -text {pressed " + string n + "}");
		tk->cmd(t, "update");
		if(rfd != nil)
			fprint(rfd, "press %d\n", n);
		sys->print("clicktest: press %d\n", n);
	m := <-menubut =>
		if(m == "exit")
			break;
		tkclient->wmctl(t, m);
	}
	if(rfd != nil)
		fprint(rfd, "end %d\n", n);
	sys->print("clicktest: %d presses\n", n);
	stop <-= 1;
}

timeout(secs: int, c: chan of string)
{
	sys->sleep(secs*1000);
	c <-= "timeout";
}
