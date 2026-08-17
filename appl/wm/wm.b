implement Wm;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Screen, Display, Image, Rect, Point, Wmcontext, Pointer: import draw;
include "wmsrv.m";
	wmsrv: Wmsrv;
	Client: import wmsrv;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "string.m";
	str: String;
include "sh.m";
include "winplace.m";
	winplace: Winplace;
include "keyboard.m";

Wm: module {
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Ptrstarted, Kbdstarted, Keyupstarted, Controlstarted, Controller, Fixedorigin, Sticky: con 1<<iota;
Bdwidth: con 3;
Sminx, Sminy, Smaxx, Smaxy: con iota;
Minx, Miny, Maxx, Maxy: con 1<<iota;
Background: con int 16rC4C0B4FF;	# Soft Plan9 Paper desktop

# Snapshot of a client window taken before the root Screen is rebuilt.
Snap: adt {
	c:	ref Client;
	tag:	string;
	nr:	Rect;
	img:	ref Image;	# display-backed copy of prior pixels (may be nil)
};

screen: ref Screen;
display: ref Display;
rootwin: ref Window;
ptrfocus: ref Client;
kbdfocus: ref Client;
controller: ref Client;
allowcontrol := 1;
fakekbd: chan of string;
fakekbdin: chan of string;
buttons := 0;
rootresizing := 0;
forceclientresize := 1;
rootresized: chan of int;
screenresize: chan of Point;
lastscreenr: Rect;
pendingsize: Point;	# host size arrived while rootreshape in flight
pendingsnaps: list of ref Snap;	# captured before root putimage greys the fb

badmodule(p: string)
{
	sys->fprint(sys->fildes(2), "wm: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys  = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		badmodule(Draw->PATH);

	str = load String String->PATH;
	if(str == nil)
		badmodule(String->PATH);

	wmsrv = load Wmsrv Wmsrv->PATH;
	if(wmsrv == nil)
		badmodule(Wmsrv->PATH);

	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		badmodule(Wmclient->PATH);
	wmclient->init();

	winplace = load Winplace Winplace->PATH;
	if(winplace == nil)
		badmodule(Winplace->PATH);
	winplace->init();

	sys->pctl(Sys->NEWPGRP|Sys->FORKNS, nil);
	if (ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	display = ctxt.display;

	buts := Wmclient->Appl;
	if(ctxt.wm == nil)
		buts = Wmclient->Plain;
	win := wmclient->window(ctxt, "Wm", buts);
	rootwin = win;
	wmclient->win.reshape(((0, 0), (100, 100)));
	wmclient->win.onscreen("place");
	if(win.image == nil){
		sys->fprint(sys->fildes(2), "wm: cannot get image to draw on\n");
		raise "fail:no image";
	}
	wmclient->win.startinput("kbd" :: "ptr" :: nil);
	wmctxt := win.ctxt;
	screen = makescreen(win.image);
	lastscreenr = screen.image.r;

	(clientwm, join, req) := wmsrv->init();
	clientctxt := ref Draw->Context(ctxt.display, nil, clientwm);

	wmrectIO := sys->file2chan("/chan", "wmrect");
	if(wmrectIO == nil)
		fatal(sys->sprint("cannot make /chan/wmrect: %r"));

	sync := chan of string;
	argv = tl argv;
	if(argv == nil)
		argv = "wm/toolbar" :: nil;
	spawn command(clientctxt, argv, sync);
	if((e := <-sync) != nil)
		fatal("cannot run command: " + e);

	fakekbd = chan of string;
	rootresized = chan of int;
	screenresize = chan of Point;
	pendingsize = (0, 0);
	spawn screenmonitor(screenresize);
	for(;;) alt {
		sz := <-screenresize =>
		if(sz.x > 0 && sz.y > 0){
			if(rootresizing){
				pendingsize = sz;
			}else{
				rootresizing = 1;
				spawn rootreshape(sz, rootresized);
			}
		}
	c := <-win.ctl or
	c = <-wmctxt.ctl =>
		# XXX could implement "pleaseexit" in order that
		# applications can raise a warning message before
		# they're unceremoniously dumped.
		if(c == "exit")
			for(z := wmsrv->top(); z != nil; z = z.znext)
				z.ctl <-= "exit";

		wmclient->win.wmctl(c);
		if(win.image != screen.image || !win.image.r.eq(lastscreenr))
			reshaped(win);
	c := <-wmctxt.kbd or
	c = int <-fakekbd =>
		if(kbdfocus != nil &&
		   (!iskeyup(c) || (kbdfocus.flags & Keyupstarted)))
			kbdfocus.kbd <-= c;
	done := <-rootresized =>
		rootresizing = 0;
		if(done == 0)
			reshaped(win);
		# Prefer an explicit pending host size; else catch display drift.
		sz := pendingsize;
		pendingsize = (0, 0);
		if(sz.x <= 0 || sz.y <= 0){
			if(display != nil && display.image != nil
			&& !samescreensize(display.image.r, lastscreenr))
				sz = display.image.r.size();
		}
		if(sz.x > 0 && sz.y > 0 && display != nil && display.image != nil
		&& !samescreensize(display.image.r, lastscreenr)){
			rootresizing = 1;
			spawn rootreshape(sz, rootresized);
		}
	p := <-wmctxt.ptr =>
		if(p.buttons == -1){
			# The host display changed size.  Resize the root window;
			# reshaped() will rebuild the screen and reflow all clients.
			if(p.xy.x > 0 && p.xy.y > 0){
				if(rootresizing)
					pendingsize = p.xy;
				else{
					rootresizing = 1;
					spawn rootreshape(p.xy, rootresized);
				}
			}
			continue;
		}
		if(wmclient->win.pointer(*p))
			break;
		if(p.buttons && (ptrfocus == nil || buttons == 0)){
			c := wmsrv->find(p.xy);
			if(c != nil){
				ptrfocus = c;
				if((c.flags & Sticky) == 0)
					c.ctl <-= "raise";
				setfocus(win, c);
			}
		}
		if(ptrfocus != nil && (ptrfocus.flags & Ptrstarted) != 0){
			# inside currently selected client or it had button down last time (might have come up)
			buttons = p.buttons;
			ptrfocus.ptr <-= p;
			break;
		}
		buttons = 0;
	(c, rc) := <-join =>
		rc <-= nil;
		# new client; inform it of the available screen rectangle.
		# XXX do we need to do this now we've got wmrect?
		# Spawned: the client hasn't reached its ctl-reading loop yet
		# (see sendctl above) - a direct send here can deadlock against
		# the client's own setup requests.
		spawn sendctl(c.ctl, "rect " + r2s(screen.image.r));
		if(allowcontrol){
			controller = c;
			c.flags |= Controller;
			allowcontrol = 0;
		}else {
			controlevent("newclient " + string c.id);
			# Raise the new client so it's visible and on top
			c.top();
			# Set keyboard focus to the new client
			setfocus(win, c);
		}
		c.cursor = "cursor";
	(c, data, rc) := <-req =>
		# if client leaving
		if(rc == nil){
			c.remove();
			if(c.stop == nil)
				break;
			if(c == ptrfocus)
				ptrfocus = nil;
			if(c == kbdfocus)
				kbdfocus = nil;
			if(c == controller)
				controller = nil;
			controlevent("delclient " + string c.id);
			for(z := wmsrv->top(); z != nil; z = z.znext)
				if(z.flags & Kbdstarted)
					break;
			setfocus(win, z);
			c.stop <-= 1;
			break;
		}
		err := handlerequest(win, wmctxt, c, string data);
		n := len data;
		if(err != nil)
			n = -1;
		# Spawn reply: must not block the wm alt (stalls all new clients),
		# and must not alt/`*` (can drop a live FileIO reply).
		spawn freply(rc, n, err);
	(nil, nil, nil, wc) := <-wmrectIO.write =>
		if(wc == nil)
			break;
		spawn freply(wc, 0, "cannot write");
	(off, nil, nil, rc) := <-wmrectIO.read =>
		if(rc == nil)
			break;
		d := array of byte r2s(screen.image.r);
		if(off > big len d)
			off = big len d;
		spawn freplyb(rc, d[int off:], nil); # TODO potential bug truncating big to int
	}
}

# Keyup contains the generic special-key prefix as well as the release bit.
# A simple `c & Keyup` therefore also matches ordinary arrow/function key
# presses.  Match the complete encoded tag and leave its low 11 key bits out.
iskeyup(c: int): int
{
	return (c & (Keyboard->Spec | 16r800)) == Keyboard->Keyup;
}

screenmonitor(ch: chan of Point)
{
	fd := sys->open("/dev/screen", Sys->OREAD);
	if(fd == nil)
		return;
	last := Point(0, 0);
	for(;;){
		buf := array[5*12] of byte;
		sys->seek(fd, big 0, 0);
		n := sys->read(fd, buf, len buf);
		if(n > 48){
			sz := Point(int string buf[36:47], int string buf[48:]);
			if(sz.x != last.x || sz.y != last.y){
				last = sz;
				ch <-= sz;
			}
		}
		sys->sleep(100);
	}
}

samescreensize(a, b: Rect): int
{
	return a.dx() > 0 && a.dy() > 0 && a.dx() == b.dx() && a.dy() == b.dy();
}

rootreshape(size: Point, done: chan of int)
{
	# Prefer the live Display root rectangle: host softscreen / drawdisplayresize
	# may have advanced past the size that woke us during a live drag.
	r := ((0, 0), size);
	if(display != nil && display.image != nil)
		r = ((0, 0), display.image.r.size());
	# Same pixel size as the last completed reshape: do not tear down clients.
	# Compare dx/dy only — origin differences must not force a rebuild.
	# (Deminiaturize and duplicate host notifies used to hit this path and
	# replace every app window with an empty placeholder.)
	if(samescreensize(lastscreenr, r)){
		if(rootwin.image != nil)
			rootwin.image.flush(Draw->Flushnow);
		done <-= 1;
		return;
	}
	# Snapshot client pixels BEFORE putimage rebuilds the root window.
	# That rebuild paints Background over the shared framebuffer and, for
	# Refnone root layers, permanently erases the app pixels that a later
	# reshaped() snapshot would otherwise try to recover.
	pendingsnaps = capturesnaps(r);
	rootwin.r = rootwin.screenr(r);
	# Drop the cached root image so putimage rebuilds the window layer.
	# Do not clear rootwin.screen: Window.reshape returns early when screen is nil.
	rootwin.image = nil;
	err := rootwin.wmctl(sys->sprint("!reshape . -1 %s", r2s(rootwin.r)));
	if(err != nil)
		sys->fprint(sys->fildes(2), "wm: root reshape: %s\n", err);
	if(rootwin.image != nil){
		# Paint immediately so the White screen fill from putimage never shows.
		bg := rootwin.image.display.color(Background);
		rootwin.image.clipr = rootwin.image.r;
		rootwin.image.draw(rootwin.image.r, bg, nil, bg.r.min);
		rootwin.image.flush(Draw->Flushnow);
	}
	done <-= 0;
}

# Send on a client's ctl channel without blocking the caller: at join
# time the client hasn't reached its own event loop yet (it's still
# inside wmclient->window()), so a plain c.ctl <-= would stall this
# whole dispatch loop until the client gets there - and deadlock if the
# client's own next step needs a reply from us first.
sendctl(c: chan of string, s: string)
{
	c <-= s;
}

# Like sendctl, but for two messages that must arrive in order - spawning
# each separately wouldn't guarantee that.
sendctl2(c: chan of string, s1, s2: string)
{
	c <-= s1;
	c <-= s2;
}

freply(rc: Sys->Rwrite, n: int, err: string)
{
	if(rc != nil)
		rc <-= (n, err);
}

freplyb(rc: Sys->Rread, d: array of byte, err: string)
{
	if(rc != nil)
		rc <-= (d, err);
}

handlerequest(win: ref Wmclient->Window, wmctxt: ref Wmcontext, c: ref Client, req: string): string
{
#sys->print("%d: %s\n", c.id, req);
	args := str->unquoted(req);
	if(args == nil)
		return "no request";
	n := len args;
	if(req[0] == '!' && n < 3)
		return "bad arg count";

	case hd args {
	"key" =>
		# XXX should we restrict this capability to certain clients only?
		if(n != 2)
			return "bad arg count";
		if(fakekbdin == nil){
			fakekbdin = chan of string;
			spawn bufferproc(fakekbdin, fakekbd);
		}
		fakekbdin <-= hd tl args;

	"ptr" =>
		# ptr x y
		if(n != 3)
			return "bad arg count";
		if(ptrfocus != c)
			return "cannot move pointer";
		e := wmclient->win.wmctl(req);
		if(e == nil){
			c.ptr <-= nil;		# flush queue
			c.ptr <-= ref Pointer(buttons, (int hd tl args, int hd tl tl args), sys->millisec());
		}

	"cursor" =>
		# cursor hotx hoty dx dy data
		if(n != 6 && n != 1)
			return "bad arg count";
		c.cursor = req;
		if(ptrfocus == c || kbdfocus == c)
			return wmclient->win.wmctl(c.cursor);

	"start" =>
		if(n != 2)
			return "bad arg count";
		case hd tl args {
		"mouse" or
		"ptr" =>
			c.flags |= Ptrstarted;
		"kbd" =>
			c.flags |= Kbdstarted;
			# XXX this means that any new window grabs the focus from the current
			# application, but usually you want this to happen... how can we distinguish
			# the two cases?
			setfocus(win, c);
		"keyup" =>
			# Releases are opt-in: otherwise their private key codes would
			# appear as garbage characters in ordinary text widgets.
			c.flags |= Keyupstarted;
		"control" =>
			if((c.flags & Controller) == 0)
				return "control not available";
			c.flags |= Controlstarted;
		* =>
			return "unknown input source";
		}

	"!reshape" =>
		# reshape tag reqid rect [how]
		if(n < 7)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;		# skip reqid
		r: Rect;
		r.min.x = int hd args; args = tl args;
		r.min.y = int hd args; args = tl args;
		r.max.x = int hd args; args = tl args;
		r.max.y = int hd args; args = tl args;
		if(args != nil){
			case hd args{
			"onscreen" =>
				r = fitrect(r, screen.image.r);
			"place" =>
				r = fitrect(r, screen.image.r);
				r = newrect(r, screen.image.r);
			"exact" =>
				;
			"origin" =>
				w := c.window(tag);
				if(w == nil)
					return "no such tag";
				if(!w.r.size().eq(r.size()))
					return "origin move changed window size";
				if(c.setorigin(tag, r.min) == -1)
					return "can't move window";
				if((c.flags & Sticky) == 0)
					c.top();
				return nil;
			"max" =>
				r = screen.image.r;			# XXX don't obscure toolbar?
			* =>
				return "unkown placement method";
			}
		}
		return reshape(c, tag, r);

	"delete" =>
		# delete tag
		if(tl args == nil)
			return "tag required";
		c.setimage(hd tl args, nil);
		if(c.wins == nil && c == kbdfocus)
			setfocus(win, nil);

	"raise" =>
		c.top();

	"lower" =>
		c.bottom();

	"sticky" =>
		# sticky [on|off] — when on, the wm will not auto-raise this
		# client on pointer-press, so it can stay at the bottom of the
		# z-order. Pinboard uses this to be the desktop surface.
		if(n == 1 || (n == 2 && hd tl args == "on"))
			c.flags |= Sticky;
		else if(n == 2 && hd tl args == "off")
			c.flags &= ~Sticky;
		else
			return "bad sticky arg";

	"!move" or
	"!size" =>
		# !move tag reqid startx starty
		# !size tag reqid mindx mindy
		ismove := hd args == "!move";
		if(n < 3)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;			# skip reqid
		w := c.window(tag);
		if(w == nil)
			return "no such tag";
		if(ismove){
			if(n != 5)
				return "bad arg count";
			return dragwin(wmctxt.ptr, c, w, Point(int hd args, int hd tl args).sub(w.r.min));
		}else{
			if(n != 5)
				return "bad arg count";
			sizewin(wmctxt.ptr, c, w, Point(int hd args, int hd tl args));
		}

	"fixedorigin" =>
		c.flags |= Fixedorigin;

	"rect" =>
		;

	"kbdfocus" =>
		if(n != 2)
			return "bad arg count";
		if(int hd tl args)
			setfocus(win, c);
		else if(c == kbdfocus)
			setfocus(win, nil);

	# controller specific messages:
	"request" =>		# can be used to test for control.
		if((c.flags & Controller) == 0)
			return "you are not in control";

	"ctl" =>
		# ctl id msg
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		if(n < 3)
			return "bad arg count";
		id := int hd tl args;
		for(z := wmsrv->top(); z != nil; z = z.znext)
			if(z.id == id)
				break;
		if(z == nil)
			return "no such client";
		z.ctl <-= str->quoted(tl tl args);

	"endcontrol" =>
		if(c != controller)
			return "invalid request";
		controller = nil;
		allowcontrol = 1;
		c.flags &= ~(Controlstarted | Controller);

	* =>
		if(c == controller || controller == nil || (controller.flags & Controlstarted) == 0)
			return "unknown control request";
		controller.ctl <-= "request " + string c.id + " " + req;
	}
	return nil;
}

# Keep each client in its prior screen rectangle (clamped if the host shrank).
# Do not scale with the host size: after a grow the apps must remain in their
# original bounding boxes with only the newly exposed L filled in grey.
capturesnaps(newr: Rect): list of ref Snap
{
	snaps: list of ref Snap;
	if(display == nil || screen == nil)
		return nil;
	for(z := wmsrv->top(); z != nil; z = z.znext){
		for(wl := z.wins; wl != nil; wl = tl wl){
			w := hd wl;
			nr := w.r;
			# Preserve origin/size when the host grows; only fit on shrink.
			if(nr.max.x > newr.max.x || nr.max.y > newr.max.y
			|| nr.min.x < newr.min.x || nr.min.y < newr.min.y
			|| nr.dx() > newr.dx() || nr.dy() > newr.dy())
				nr = fitrect(nr, newr);
			snap: ref Image = nil;
			if(w.img != nil && w.r.dx() > 0 && w.r.dy() > 0){
				snap = display.newimage(((0, 0), w.r.size()),
					w.img.chans, 0, Background);
				if(snap != nil)
					snap.draw(snap.r, w.img, nil, w.img.r.min);
			}
			snaps = ref Snap(z, w.tag, nr, snap) :: snaps;
		}
	}
	return snaps;
}

# the window manager window has been reshaped;
# allocate a new screen, and move all the 
reshaped(win: ref Wmclient->Window)
{
	newr := win.image.r;
	snaps := pendingsnaps;
	pendingsnaps = nil;
	# Fallback when reshape did not come through rootreshape (e.g. ctl).
	# At that point the root image may already be grey — best-effort only.
	if(snaps == nil)
		snaps = capturesnaps(newr);
	sl: list of ref Snap;
	for(sl = snaps; sl != nil; sl = tl sl){
		w := (hd sl).c.window((hd sl).tag);
		if(w != nil)
			w.img = nil;
	}
	# Keep the destination clip in sync with the new root extent.  A stale
	# clip rectangle clips the background fill to the old window box while
	# allowing some direct client primitives to appear outside it.
	win.image.clipr = win.image.r;
	screen = makescreen(win.image);
	# Repaint the entire new root image explicitly.  The framebuffer is
	# preserved across a host resize, so newly exposed pixels are otherwise
	# left with their zeroed contents until a client happens to draw there.
	bg := win.image.display.color(Background);
	win.image.draw(win.image.r, bg, nil, bg.r.min);
	win.image.flush(Draw->Flushnow);
	# Recreate in reverse so z-order matches the prior top-first walk.
	for(sl = snaps; sl != nil; sl = tl sl){
		s := hd sl;
		w := s.c.window(s.tag);
		if(w == nil)
			continue;
		w.img = screen.newwindow(s.nr, Draw->Refbackup, Background);
		if(w.img != nil && s.img != nil){
			# Copy into the window's current size; fitrect may have shrunk it.
			dr := w.img.r;
			if(dr.dx() > s.img.r.dx())
				dr.max.x = dr.min.x + s.img.r.dx();
			if(dr.dy() > s.img.r.dy())
				dr.max.y = dr.min.y + s.img.r.dy();
			w.img.draw(dr, s.img, nil, s.img.r.min);
		}
		w.r = s.nr;
		# Tell the client to replace its backing image as well.  The
		# server-side window alone only lets incremental drawing (such as
		# clock hands) reach the new area; the client's image would retain
		# the old bounding box and leave its background stale.
		s.c.ctl <-= sys->sprint("!reshape %q -1 %s", s.tag, r2s(s.nr));
		s.c.ctl <-= "rect " + r2s(newr);
	}
	lastscreenr = newr;
	win.image.flush(Draw->Flushnow);
}

controlevent(e: string)
{
	if(controller != nil && (controller.flags & Controlstarted))
		controller.ctl <-= e;
}

dragwin(ptr: chan of ref Pointer, c: ref Client, w: ref Wmsrv->Window, off: Point): string
{
	if(buttons == 0)
		return "too late";
	p: ref Pointer;
	scr := screen.image.r;
	Margin: con 10;
	do{
		p = <-ptr;
		org := p.xy.sub(off);
		if(org.y < scr.min.y)
			org.y = scr.min.y;
		else if(org.y > scr.max.y - Margin)
			org.y = scr.max.y - Margin;
		if(org.x < scr.min.x && org.x + w.r.dx() < scr.min.x + Margin)
			org.x = scr.min.x + Margin - w.r.dx();
		else if(org.x > scr.max.x - Margin)
			org.x = scr.max.x - Margin;
		w.img.origin(w.img.r.min, org);
	} while (p.buttons != 0);
	c.ptr <-= p;
	buttons = 0;
	r: Rect;
	r.min = p.xy.sub(off);
	r.max = r.min.add(w.r.size());
	if(r.eq(w.r))
		return "not moved";
	reshape(c, w.tag, r);
	return nil;
}

sizewin(ptrc: chan of ref Pointer, c: ref Client, w: ref Wmsrv->Window, minsize: Point): string
{
	borders := array[4] of ref Image;
	showborders(borders, w.r, Minx|Maxx|Miny|Maxy);
	screen.image.flush(Draw->Flushnow);
	while((ptr := <-ptrc).buttons == 0)
		;
	xy := ptr.xy;
	move, show: int;
	offset := Point(0, 0);
	r := w.r;
	show = Minx|Miny|Maxx|Maxy;
	if(xy.in(w.r) == 0){
		r = (xy, xy);
		move = Maxx|Maxy;
	}else {
		if(xy.x < (r.min.x+r.max.x)/2){
			move=Minx;
			offset.x = xy.x - r.min.x;
		}else{
			move=Maxx;
			offset.x = xy.x - r.max.x;
		}
		if(xy.y < (r.min.y+r.max.y)/2){
			move |= Miny;
			offset.y = xy.y - r.min.y;
		}else{
			move |= Maxy;
			offset.y = xy.y - r.max.y;
		}
	}
	return reshape(c, w.tag, sweep(ptrc, r, offset, borders, move, show, minsize));
}

reshape(c: ref Client, tag: string, r: Rect): string
{
	w := c.window(tag);
	# Host reshape fan-out already installed a window at this rect (with a
	# pixel snapshot).  Re-push that image so the client putimage/update
	# runs — do not replace it with a fresh Nofill and erase the contents.
	if(w != nil && w.img != nil && w.r.eq(r)){
		if(c.setimage(tag, w.img) == -1)
			return "can't do two at once";
		if((c.flags & Sticky) == 0)
			c.top();
		return nil;
	}
	# if window hasn't changed size, then just change its origin and use the same image.
	if(forceclientresize == 0 && (c.flags & Fixedorigin) == 0 && w != nil && w.r.size().eq(r.size())){
		c.setorigin(tag, r.min);
	} else {
		old: ref Image = nil;
		if(w != nil)
			old = w.img;
		img := screen.newwindow(r, Draw->Refbackup, Background);
		if(img == nil)
			return sys->sprint("window creation failed: %r");
		if(old != nil)
			img.draw(img.r, old, nil, old.r.min);
		if(c.setimage(tag, img) == -1)
			return "can't do two at once";
	}
	# Sticky clients (e.g. pinboard) keep their z-order.
	if((c.flags & Sticky) == 0)
		c.top();
	return nil;
}

sweep(ptr: chan of ref Pointer, r: Rect, offset: Point, borders: array of ref Image, move, show: int, min: Point): Rect
{
	while((p := <-ptr).buttons != 0){
		xy := p.xy.sub(offset);
		if(move&Minx)
			r.min.x = xy.x;
		if(move&Miny)
			r.min.y = xy.y;
		if(move&Maxx)
			r.max.x = xy.x;
		if(move&Maxy)
			r.max.y = xy.y;
		showborders(borders, r, show);
	}
	r = r.canon();
	if(r.min.y < screen.image.r.min.y){
		r.min.y = screen.image.r.min.y;
		r = r.canon();
	}
	if(r.dx() < min.x){
		if(move & Maxx)
			r.max.x = r.min.x + min.x;
		else
			r.min.x = r.max.x - min.x;
	}
	if(r.dy() < min.y){
		if(move & Maxy)
			r.max.y = r.min.y + min.y;
		else {
			r.min.y = r.max.y - min.y;
			if(r.min.y < screen.image.r.min.y){
				r.min.y = screen.image.r.min.y;
				r.max.y = r.min.y + min.y;
			}
		}
	}
	return r;
}

showborders(b: array of ref Image, r: Rect, show: int)
{
	r = r.canon();
	b[Sminx] = showborder(b[Sminx], show&Minx,
		(r.min, (r.min.x+Bdwidth, r.max.y)));
	b[Sminy] = showborder(b[Sminy], show&Miny,
		((r.min.x+Bdwidth, r.min.y), (r.max.x-Bdwidth, r.min.y+Bdwidth)));
	b[Smaxx] = showborder(b[Smaxx], show&Maxx,
		((r.max.x-Bdwidth, r.min.y), (r.max.x, r.max.y)));
	b[Smaxy] = showborder(b[Smaxy], show&Maxy,
		((r.min.x+Bdwidth, r.max.y-Bdwidth), (r.max.x-Bdwidth, r.max.y)));
}

showborder(b: ref Image, show: int, r: Rect): ref Image
{
	if(!show)
		return nil;
	if(b != nil && b.r.size().eq(r.size()))
		b.origin(r.min, r.min);
	else
		b = screen.newwindow(r, Draw->Refbackup, Draw->Red);
	return b;
}

r2s(r: Rect): string
{
	return string r.min.x + " " + string r.min.y + " " +
			string r.max.x + " " + string r.max.y;
}

# XXX for consideration:
# do not allow applications to grab the keyboard focus
# unless there is currently no keyboard focus...
# but what about launching a new app from the taskbar:
# surely we should allow that to grab the focus?
setfocus(win: ref Wmclient->Window, new: ref Client)
{
	old := kbdfocus;
	if(old == new)
		return;
	if(new == nil)
		wmclient->win.wmctl("cursor");
	else if(old == nil || old.cursor != new.cursor)
		wmclient->win.wmctl(new.cursor);
	if(new != nil && (new.flags & Kbdstarted) == 0)
		return;
	if(old != nil)
		spawn sendctl(old.ctl, "haskbdfocus 0");

	if(new != nil){
		# new just asked to "start kbd" from inside its own synchronous
		# setup (see wm.b's handlerequest "start"/"kbd" case) and isn't
		# necessarily draining its ctl channel yet - a direct send here
		# risks the same deadlock the join handler's "rect" send had.
		spawn sendctl2(new.ctl, "raise", "haskbdfocus 1");
		kbdfocus = new;
	} else
		kbdfocus = nil;
}

makescreen(img: ref Image): ref Screen
{
	screen = Screen.allocate(img, img.display.color(Background), 0);
	img.draw(img.r, screen.fill, nil, screen.fill.r.min);
	return screen;
}

kill(pid: int, note: string): int
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm: %s\n", s);
	kill(sys->pctl(0, nil), "killgrp");
	raise "fail:error";
}

# fit a window rectangle to the available space.
# try to preserve requested location if possible.
# make sure that the window is no bigger than
# the screen, and that its top and left-hand edges
# will be visible at least.
fitrect(w, r: Rect): Rect
{
	if(w.dx() > r.dx())
		w.max.x = w.min.x + r.dx();
	if(w.dy() > r.dy())
		w.max.y = w.min.y + r.dy();
	size := w.size();
	if (w.max.x > r.max.x)
		(w.min.x, w.max.x) = (r.min.x - size.x, r.max.x - size.x);
	if (w.max.y > r.max.y)
		(w.min.y, w.max.y) = (r.min.y - size.y, r.max.y - size.y);
	if (w.min.x < r.min.x)
		(w.min.x, w.max.x) = (r.min.x, r.min.x + size.x);
	if (w.min.y < r.min.y)
		(w.min.y, w.max.y) = (r.min.y, r.min.y + size.y);
	return w;
}

lastrect: Rect;
# find an suitable area for a window
newrect(w, r: Rect): Rect
{
	rl: list of Rect;
	for(z := wmsrv->top(); z != nil; z = z.znext)
		for(wl := z.wins; wl != nil; wl = tl wl)
			rl = (hd wl).r :: rl;
	lastrect = winplace->place(rl, r, lastrect, w.size());
	return lastrect;
}

bufferproc(in, out: chan of string)
{
	h, t: list of string;
	dummyout := chan of string;
	for(;;){
		outc := dummyout;
		s: string;
		if(h != nil || t != nil){
			outc = out;
			if(h == nil)
				for(; t != nil; t = tl t)
					h = hd t :: h;
			s = hd h;
		}
		alt{
		x := <-in =>
			t = x :: t;
		outc <-= s =>
			h = tl h;
		}
	}
}

command(ctxt: ref Draw->Context, args: list of string, sync: chan of string)
{
	if((sh := load Sh Sh->PATH) != nil){
		sh->run(ctxt, "{$*&}" :: args);
		sync <-= nil;
		return;
	}
	fds := list of {0, 1, 2};
	sys->pctl(sys->NEWFD, fds);

	cmd := hd args;
	file := cmd;

	if(len file<4 || file[len file-4:]!=".dis")
		file += ".dis";

	c := load Wm file;
	if(c == nil) {
		err := sys->sprint("%r");
		if(err != "permission denied" && err != "access permission denied" && file[0]!='/' && file[0:2]!="./"){
			c = load Wm "/dis/"+file;
			if(c == nil)
				err = sys->sprint("%r");
		}
		if(c == nil){
			sync <-= sys->sprint("%s: %s\n", cmd, err);
			exit;
		}
	}
	sync <-= nil;
	c->init(ctxt, args);
}
