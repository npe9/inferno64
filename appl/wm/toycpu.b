implement Wmtoycpu;

# Nelson's Dream Machines chapter on Bucky's Wristwatch/"Rock Bottom" -
# appl/lib/toycpu.b (module/toycpu.m) is the actual minimal machine (an
# assembler plus a ten-instruction Little-Man-Computer-style VM); this
# file is just the front panel: a live dump of all 100 mailboxes with
# the program counter's own mailbox marked, Step/Run/Reset controls,
# and an input box that only matters once the machine is actually
# blocked waiting for one.
#
# usage: wm/toycpu [program.lmc]

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

include "toycpu.m";
	toycpu: Toycpu;

Wmtoycpu: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

window: ref Tk->Toplevel;
initmem: array of int;
m: ref Toycpu->Machine;
progpath := "/lib/toycpu/countdown.lmc";
waiting := 0;

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
	toycpu = load Toycpu Toycpu->PATH;
	if(toycpu == nil)
		loaderr(Toycpu->PATH);
	toycpu->init();

	argv = tl argv;
	if(argv != nil)
		progpath = hd argv;

	if(loadprogram() != nil)
		raise "fail:load";

	tkclient->init();
	buts := Tkclient->Resize | Tkclient->Hide;
	winctl: chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Toy CPU", buts);
	cmdc := chan of string;
	tk->namechan(window, cmdc, "cmd");
	for(tc := 0; tc < len tkconfig; tc++)
		tkcmd(window, tkconfig[tc]);
	if((e := tkcmd(window, "variable lasterror")) != nil){
		sys->fprint(sys->fildes(2), "toycpu: tk initialization failed: %s\n", e);
		raise "fail:tk";
	}
	fittoscreen(window);
	tkcmd(window, "update");

	setstatus("loaded " + progpath + " - ready (s=step r=run t=reset)");
	render();

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

loadprogram(): string
{
	fd := sys->open(progpath, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "toycpu: cannot open %s: %r\n", progpath);
		return "open";
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0){
		sys->fprint(sys->fildes(2), "toycpu: cannot stat %s\n", progpath);
		return "stat";
	}
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0){
		sys->fprint(sys->fildes(2), "toycpu: cannot read %s: %r\n", progpath);
		return "read";
	}
	(mem, err) := toycpu->assemble(string a[0:n]);
	if(mem == nil){
		sys->fprint(sys->fildes(2), "toycpu: %s: %s\n", progpath, err);
		return "assemble";
	}
	initmem = mem;
	m = toycpu->newmachine(initmem);
	waiting = 0;
	return nil;
}

tkconfig := array[] of {
	"frame .view",
	"text .view.t -state disabled -bd 4 -width 0 -height 0 -bg white -font /fonts/vera/veramono/veramono.12.font",
	"pack .view.t -expand 1 -fill both",

	"frame .ctl",
	"button .ctl.step -text Step -command {send cmd step}",
	"button .ctl.run -text Run -command {send cmd run}",
	"button .ctl.reset -text Reset -command {send cmd reset}",
	"label .ctl.status -text {} -anchor w",
	"pack .ctl.step -side left",
	"pack .ctl.run -side left -padx 4",
	"pack .ctl.reset -side left -padx 4",
	"pack .ctl.status -side left -expand 1 -fill x -padx 8",

	"frame .in",
	"label .in.l -text {input:}",
	"entry .in.e -bg white -width 6",
	"button .in.submit -text Submit -command {send cmd input}",
	"pack .in.l -side left",
	"pack .in.e -side left -padx 4",
	"pack .in.submit -side left",
	"bind .in.e <Key-\n> {send cmd input}",
	"bind . <Key-s> {send cmd step}",
	"bind . <Key-r> {send cmd run}",
	"bind . <Key-t> {send cmd reset}",
	"bind .in.e <Key-s> {send cmd step}",
	"bind .in.e <Key-r> {send cmd run}",
	"bind .in.e <Key-t> {send cmd reset}",

	"pack .view -expand 1 -fill both",
	"pack .ctl -fill x",
	"pack .in -fill x",
	"pack propagate . 0",
	". configure -width 640 -height 520",
	"focus .in.e",
};

docmd(s: string)
{
	case s {
	"step" =>
		dostep();
		render();
	"run" =>
		dorun();
		render();
	"reset" =>
		m = toycpu->newmachine(initmem);
		waiting = 0;
		setstatus("reset - ready");
		render();
	"input" =>
		if(!waiting)
			return;
		txt := tkcmd(window, ".in.e get");
		if(txt == "")
			return;
		toycpu->input(m, toint(txt));
		tkcmd(window, ".in.e delete 0 end");
		waiting = 0;
		dostep();
		render();
	}
}

dostep()
{
	status := toycpu->step(m);
	handlestatus(status);
}

dorun()
{
	status := "";
	nsteps := 0;
	while(status == "" && nsteps < 20000){
		status = toycpu->step(m);
		nsteps++;
	}
	if(status == "" )
		setstatus(sys->sprint("stopped after %d steps (possible infinite loop)", nsteps));
	else
		handlestatus(status);
}

handlestatus(status: string)
{
	case status {
	"" =>
		setstatus("running");
	"halt" =>
		waiting = 0;
		setstatus(sys->sprint("halted - acc=%03d", m.acc));
	"input" =>
		waiting = 1;
		setstatus("waiting for input - type a number and Submit");
	* =>
		waiting = 0;
		setstatus(status);
	}
}

render()
{
	tkcmd(window, ".view.t configure -state normal");
	tkcmd(window, ".view.t delete 1.0 end");
	tkcmd(window, ".view.t insert end " + tk->quote(dumptext()));
	tkcmd(window, ".view.t configure -state disabled");
}

dumptext(): string
{
	s := sys->sprint("ACC:%03d  PC:%02d  NEG:%d\n\n", m.acc, m.pc, m.negflag);
	for(row := 0; row < Toycpu->Mem/10; row++){
		line := "";
		for(col := 0; col < 10; col++){
			addr := row*10+col;
			mark := "  ";
			if(addr == m.pc && !m.halted)
				mark = "->";
			line += sys->sprint("%s%02d:%03d ", mark, addr, m.mem[addr]);
		}
		s += line + "\n";
	}
	s += "\nOUTPUT:";
	for(o := m.outq; o != nil; o = tl o)
		s += sys->sprint(" %d", hd o);
	s += "\n";
	return s;
}

setstatus(s: string)
{
	tkcmd(window, ".ctl.status configure -text " + tk->quote(s));
}

toint(s: string): int
{
	neg := 0;
	i := 0;
	if(len s > 0 && s[0] == '-'){
		neg = 1;
		i = 1;
	}
	v := 0;
	for(; i < len s; i++)
		if(s[i] >= '0' && s[i] <= '9')
			v = v*10 + (s[i]-'0');
	if(neg)
		return -v;
	return v;
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
