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
	"label .l -text {nothing yet} -width 200",
	"pack .b .l -in .f",
	"pack .f -fill both -expand 1",
	"pack propagate . 0",
	"update",
};

# The label is given a fixed width on purpose. Without one its text changes
# width when a press is recorded, pack re-centres what is beside it, and the
# button moves out from under the next click - two clicks in five went missing
# that way, which looks like clicks being dropped and is a widget that walked.
#
# A menu is the case a click alone does not cover: it posts on a press and
# tracks the pointer, so an item is chosen by moving onto it rather than by
# clicking where it happens to be. That is what session(2) keeps pointer
# movement for, and until this it was a reason rather than a demonstration.
menucfg := array[] of {
	"frame .f",
	"menubutton .mb -text Menu -menu .mb.m",
	"menu .mb.m",
	".mb.m add command -label one -command {send cmd one}",
	".mb.m add command -label two -command {send cmd two}",
	".mb.m add command -label three -command {send cmd three}",
	"label .l -text {nothing yet} -width 200",
	"pack .mb .l -in .f",
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
	menu := 0;
	item := 2;
	expect := "";
	want := 0;
	arg->init(argv);
	arg->setusage("clicktest [-m] [-i item] [-e what -n count] [-w wherefile] [-r resultfile] [-t seconds]");
	while((o := arg->opt()) != 0)
		case o {
		'w' =>	where = arg->earg();
		'r' =>	result = arg->earg();
		't' =>	wait = int arg->earg();
		'm' =>	menu++;		# a menu instead of a button
		'i' =>	item = int arg->earg();	# which item to aim the drag at
		'e' =>	expect = arg->earg();	# what should arrive
		'n' =>	want = int arg->earg();	# and how many times
		* =>	arg->usage();
		}

	if(ctxt == nil){
		fprint(sys->fildes(2), "clicktest: no window context\n");
		raise "fail:context";
	}

	tkclient->init();
	(t, menubut) := tkclient->toplevel(ctxt, "", "clicktest", 0);
	tkc := cfg;
	if(menu)
		tkc = menucfg;
	for(i := 0; i < len tkc; i++)
		tk->cmd(t, tkc[i]);

	cmd := chan of string;
	tk->namechan(t, cmd, "cmd");
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);
	tk->cmd(t, "update");

	# Where the button really is, in screen coordinates, which is the only
	# thing a script can act on. -actx and -acty are the position Tk gave
	# the widget after packing; the toplevel's own position has to be added
	# because a widget's is relative to it.
	w := ".b";
	if(menu)
		w = ".mb";
	bx := int tk->cmd(t, w + " cget -actx");
	by := int tk->cmd(t, w + " cget -acty");
	bw := int tk->cmd(t, w + " cget -actwidth");
	bh := int tk->cmd(t, w + " cget -actheight");
	tx := int tk->cmd(t, ". cget -actx");
	ty := int tk->cmd(t, ". cget -acty");
	(cx, cy) := (tx + bx + bw/2, ty + by + bh/2);

	wfd := sys->create(where, Sys->OWRITE, 8r666);
	if(wfd == nil){
		fprint(sys->fildes(2), "clicktest: %s: %r\n", where);
		raise "fail:create";
	}
	if(menu){
		# A menu posts on the press and tracks the pointer, so an item
		# is taken by moving onto it and releasing there - which is a
		# drag. The file holds exactly the four numbers a drag wants,
		# aimed at the middle item, so a script needs no arithmetic:
		#	session drag `{cat /clicktest.where} 1
		# Measure the menu rather than assume it sits flush under its
		# button with items the button's height. Posting it, reading
		# its real geometry and unposting is the only way to be right
		# about a border and padding that are not this program's to
		# know. Guessing put the release on the first item while aiming
		# at the second, which looks like a menu that ignored the
		# pointer and is not one.
		tk->cmd(t, ".mb.m post " + string cx + " " + string (ty+by+bh));
		tk->cmd(t, "update");
		my := int tk->cmd(t, ".mb.m cget -acty");
		mh := int tk->cmd(t, ".mb.m cget -actheight");
		tk->cmd(t, ".mb.m unpost");
		tk->cmd(t, "update");
		if(mh <= 0){
			my = ty + by + bh;
			mh = 3 * bh;		# nothing better to go on
		}
		ih := mh / 3;			# three items
		if(item < 1)
			item = 1;
		if(item > 3)
			item = 3;
		iy := my + (item-1)*ih + ih/2;
		fprint(wfd, "%d %d %d %d\n", cx, cy, cx, iy);
		sys->print("clicktest: menu at %d %d, item %d at %d %d\n",
			cx, cy, item, cx, iy);
	}else{
		fprint(wfd, "%d %d\n", cx, cy);
		sys->print("clicktest: the button's centre is at %d %d\n", cx, cy);
	}
	wfd = nil;

	w0 := tk->cmd(t, ". cget -actwidth");
	h0 := tk->cmd(t, ". cget -actheight");
	sys->print("clicktest: toplevel starts %sx%s\n", w0, h0);

	stop := chan of int;
	spawn tkclient->handler(t, stop);
	spawn timeout(wait, cmd);

	n := 0;
	wrong := 0;
	rfd := sys->create(result, Sys->OWRITE, 8r666);
	# a flag rather than break: in Limbo a break inside an alt arm leaves
	# the alt, not the loop around it, so the loop never ended and every
	# check below was unreachable - which looked exactly like a check that
	# had not been written
	done := 0;
	while(!done)alt{
	c := <-cmd =>
		if(c == "timeout"){
			done = 1;
			break;
		}
		n++;
		if(expect != "" && c != expect)
			wrong++;
		tk->cmd(t, ".l configure -text {" + c + " " + string n + "}");
		tk->cmd(t, "update");
		if(rfd != nil)
			fprint(rfd, "%s %d\n", c, n);
		sys->print("clicktest: %s %d\n", c, n);
	m := <-menubut =>
		if(m == "exit"){
			done = 1;
			break;
		}
		tkclient->wmctl(t, m);
	}
	if(rfd != nil)
		fprint(rfd, "end %d\n", n);
	# The toplevel's size again at the end. One window measured twice is the
	# only way to see whether the screen changed under it: two windows give
	# two positions because wm places them differently, which says nothing.
	sys->print("clicktest: toplevel was %sx%s, now %sx%s\n", w0, h0,
		tk->cmd(t, ". cget -actwidth"), tk->cmd(t, ". cget -actheight"));
	sys->print("clicktest: %d presses\n", n);
	stop <-= 1;

	# With -e and -n this is a check rather than a measurement, and says so
	# in its exit status, so a script can fail. Without them it only
	# reports, which is what it was built to do.
	if(expect != "" || want != 0){
		if(want != 0 && n != want){
			sys->print("clicktest: FAIL wanted %d presses, got %d\n", want, n);
			raise "fail:count";
		}
		if(wrong != 0){
			sys->print("clicktest: FAIL %d of %d presses were not %s\n",
				wrong, n, expect);
			raise "fail:wrong";
		}
		sys->print("clicktest: PASS\n");
	}
}

timeout(secs: int, c: chan of string)
{
	sys->sleep(secs*1000);
	c <-= "timeout";
}
