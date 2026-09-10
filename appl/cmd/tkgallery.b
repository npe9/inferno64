implement Tkgallery;

# Render one of every widget into an image and write it out, so that a
# look can be looked at.
#
# On screen this cannot be done: under the Metal present path
# Image.readpixels returns 00 00 00 both for a window on the display's
# screen and for display.image itself, so what a widget put on the page
# is invisible to the program that drew it.  A Tk toplevel does not have
# to be given the display's screen, though - allocate a Screen over an
# ordinary image, make a window in it, and hand the toplevel that window
# under the request id tkclient uses when there is no window manager,
# "-1".  Tk then draws into memory, where readpixels works.  That is the
# same trick tkofftest(1) uses to measure widgets; this one is for
# seeing them.
#
# The output is PPM because PPM is nine lines of code and needs nothing
# from the tree.  Anything on the far side can turn it into a PNG.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Screen: import draw;
include "tk.m";
	tk: Tk;
include "tknotebook.m";
	tknotebook: Tknotebook;
	Notebook: import tknotebook;
include "tkspinbox.m";
	tkspinbox: Tkspinbox;
include "arg.m";

Tkgallery: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 780;
H: con 620;

disp: ref Display;
off: ref Image;
scr: ref Screen;
win: ref Image;
font := "";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tknotebook = load Tknotebook Tknotebook->PATH;
	tkspinbox = load Tkspinbox Tkspinbox->PATH;
	if(tknotebook != nil)
		tknotebook->init();
	if(tkspinbox != nil)
		tkspinbox->init();
	arg := load Arg Arg->PATH;

	out := "gallery";
	if(arg != nil){
		arg->init(argv);
		arg->setusage("tkgallery [-f font] [-o prefix]");
		while((c := arg->opt()) != 0)
			case c {
			'f' =>	font = arg->earg();
			'o' =>	out = arg->earg();
			* =>	arg->usage();
			}
	}

	if(tk == nil){
		sys->print("tkgallery: no tk: %r\n");
		raise "fail:no tk";
	}
	disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("tkgallery: no display: %r\n");
		raise "fail:no display";
	}
	off = disp.newimage(Rect((0,0),(W,H)), Draw->RGB24, 0, Draw->White);
	scr = Screen.allocate(off, disp.color(Draw->White), 0);
	win = scr.newwindow(off.r, Draw->Refbackup, Draw->Nofill);
	if(off == nil || scr == nil || win == nil){
		sys->print("tkgallery: no offscreen screen: %r\n");
		raise "fail:no screen";
	}

	for(l := list of {"classic", "flat"}; l != nil; l = tl l){
		st := hd l;
		one(st);
		f := out + "-" + st + ".ppm";
		if(ppm(f))
			sys->print("tkgallery: wrote %s (%dx%d)\n", f, W, H);
		else
			sys->print("tkgallery: cannot write %s: %r\n", f);
	}
}

# Sizes here are DISTANCES, not character cells.  Real Tk's -width on an
# entry or a listbox counts characters; this one counts pixels (see the
# `dist' in entry(9) and listbox(9)), so -width 22 is a field three
# letters wide rather than twenty-two, and -height 3 is a listbox three
# pixels tall.  Both of those were in the first version of this file.

# every widget there is, once, in the given style
one(style: string)
{
	off.draw(off.r, disp.color(Draw->White), nil, off.r.min);
	top := tk->toplevel(disp, opts());
	if(top == nil)
		return;
	top.screenr = off.r;

	# Before any widget: style(9)'s spacings and border widths are read
	# when a widget is configured, so a style set afterwards would reach
	# the borders and not the sizes.
	cmd(top, "style " + style);

	# The window manager's toolbar, built the way wm/toolbar.b builds it:
	# a frame, a menubutton for the start menu, and one button per task
	# packed to the left, each -takefocus 0.  Reproduced rather than
	# driven, because the real one needs a running wm.
	cmd(top, "frame .tb -borderwidth 1 -relief raised");
	cmd(top, "menubutton .tb.start -text {Start} -borderwidth 0");
	cmd(top, "pack .tb.start -side left");
	tasks := array[] of {"sh", "edit  charter.ms", "acme", "wm/logon"};
	for(i := 0; i < len tasks; i++){
		b := sys->sprint(".tb.t%d", i);
		cmd(top, sys->sprint("button %s -text %s -takefocus 0",
			b, tk->quote(tasks[i])));
		cmd(top, "pack " + b + " -side left -fill y");
	}
	cmd(top, "pack .tb -side top -fill x");

	cmd(top, "frame .l");
	cmd(top, "frame .r");

	head(top, ".l.h", "buttons and choices — " + style);
	cmd(top, "label .l.lab -text {A plain label}");
	cmd(top, "button .l.but -text {Cancel}");
	cmd(top, "checkbutton .l.chk -text {Wrap long lines} -variable c1");
	cmd(top, ".l.chk select");
	cmd(top, "checkbutton .l.chk2 -text {Not wrapped} -variable c2");
	cmd(top, "radiobutton .l.r1 -text {Every third line} -variable r -value 0");
	cmd(top, "radiobutton .l.r2 -text {Every line} -variable r -value 1");
	cmd(top, ".l.r1 select");
	cmd(top, "checkbutton .l.ind -text {Indicator off, chosen} " +
		"-indicatoron 0 -variable c3");
	cmd(top, ".l.ind select");
	cmd(top, "menubutton .l.mb -text {File}");
	cmd(top, "choicebutton .l.cb -values {Red Green Blue} -variable cbv");
	packcol(top, ".l", ".l.h" :: ".l.lab" :: ".l.but" :: ".l.chk" ::
		".l.chk2" :: ".l.r1" :: ".l.r2" :: ".l.ind" :: ".l.mb" ::
		".l.cb" :: nil);

	head(top, ".r.h", "fields, ranges and containers");
	cmd(top, "entry .r.e -width 190");
	cmd(top, ".r.e insert 0 {a text field}");
	cmd(top, "scale .r.s -orient horizontal -from 0 -to 100 -length 180");
	cmd(top, ".r.s set 40");
	cmd(top, "scrollbar .r.sb -orient horizontal -width 190");
	cmd(top, ".r.sb set 0.2 0.6");
	cmd(top, "listbox .r.lb -width 190 -height 58");
	cmd(top, ".r.lb insert end {first} {second} {third}");
	cmd(top, "text .r.t -width 190 -height 46");
	cmd(top, ".r.t insert end {a text widget\nwith two lines}");
	if(tkspinbox != nil){
		(nil, nil) = tkspinbox->new(top, ".r.sp", 0, 100, 5, 25);
	}
	reliefs(top, ".r.rel");
	packcol(top, ".r", ".r.h" :: ".r.e" :: ".r.s" :: ".r.sb" :: ".r.lb" ::
		".r.t" :: ".r.sp" :: ".r.rel" :: nil);

	# The notebook claims the bottom BEFORE the columns claim the left.
	# Packed afterwards it gets only what is left over, which put it in
	# the bottom-right corner with its tabs running off the edge - pack
	# order is allocation order, not drawing order.
	if(tknotebook != nil){
		nb := tknotebook->new(top, ".nb",
			array[] of {"General", "Fonts", "Advanced"});
		if(nb != nil){
			cmd(top, "label " + nb.page(0) + ".x " +
				"-text {a notebook, whose tabs are radiobuttons}");
			cmd(top, "pack " + nb.page(0) + ".x -anchor w");
			cmd(top, "pack .nb -side bottom -anchor w -padx 12 -pady 10");
		}
	}

	cmd(top, "pack .l -side left -anchor n -padx 12 -pady 10");
	cmd(top, "pack .r -side left -anchor n -padx 12 -pady 10");

	if((e := tk->putimage(top, ". -1", win, nil)) != nil && len e > 0)
		sys->print("tkgallery: putimage: %s\n", e);
	cmd(top, "update");
}

# a row of frames, one per relief, so the border itself is the subject
reliefs(top: ref Tk->Toplevel, path: string)
{
	cmd(top, "frame " + path);
	rs := array[] of {"flat", "raised", "sunken", "groove", "ridge"};
	for(i := 0; i < len rs; i++){
		f := sys->sprint("%s.f%d", path, i);
		cmd(top, sys->sprint(
			"frame %s -width 56 -height 34 -borderwidth 2 -relief %s",
			f, rs[i]));
		cmd(top, "pack " + f + " -side left -padx 3");
	}
}

head(top: ref Tk->Toplevel, path, text: string)
{
	cmd(top, sys->sprint("label %s -text %s", path, tk->quote(text)));
}

packcol(top: ref Tk->Toplevel, nil: string, ws: list of string)
{
	for(; ws != nil; ws = tl ws)
		cmd(top, "pack " + hd ws + " -anchor w -pady 3");
}

opts(): string
{
	if(font == "")
		return "";
	return "-font " + font;
}

# tk->cmd reports an error by returning a string that starts '!', which
# is not the same as returning nil.  Saying so is the whole reason this
# wrapper exists: a mistyped option is otherwise a widget that silently
# is not there.
cmd(top: ref Tk->Toplevel, s: string)
{
	e := tk->cmd(top, s);
	if(e != nil && len e > 0 && e[0] == '!')
		sys->print("tkgallery: %s: %s\n", s, e);
}

# P6, which is a header and the bytes.  readpixels hands back RGB24 in
# memory order, so byte 0 of a pixel is BLUE; PPM wants red first.
ppm(path: string): int
{
	n := W*H;
	b := array[n*3] of byte;
	if(off.readpixels(off.r, b) != len b)
		return 0;
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return 0;
	hdr := array of byte sys->sprint("P6\n%d %d\n255\n", W, H);
	if(sys->write(fd, hdr, len hdr) != len hdr)
		return 0;
	o := array[n*3] of byte;
	for(i := 0; i < n*3; i += 3){
		o[i] = b[i+2];
		o[i+1] = b[i+1];
		o[i+2] = b[i];
	}
	return sys->write(fd, o, len o) == len o;
}
