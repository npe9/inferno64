implement Budget;

# TempleOS Apps/Budget — Tk ledger stand-in for DolDoc budget editor
# GAP: no DolDoc forms; no StrFile acct table colors; no periodic templates

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

include "daytime.m";
	daytime: Daytime;

include "env.m";
	env: Env;

Budget: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Entry: adt {
	date: string;
	credit: string;
	debit: string;
	amount: real;
	desc: string;
};

top: ref Toplevel;
entries: list of ref Entry;
viewacct := "BANK";
datafile: string;

cfg := array[] of {
	"frame .f",
	"label .f.gap -fg #884400 -text {GAP: plain Tk ledger — no DolDoc / templates / acct colors}",
	"frame .f.v",
	"label .f.v.l -text {View account:}",
	"entry .f.v.e -width 12",
	"label .f.v.b -text {balance 0.00} -width 24 -anchor w",
	"pack .f.v.l .f.v.e .f.v.b -side left -padx 4",
	"frame .f.form",
	"label .f.form.ld -text Date",
	"entry .f.form.d -width 12",
	"label .f.form.lc -text Credit",
	"entry .f.form.c -width 10",
	"label .f.form.lk -text Debit",
	"entry .f.form.k -width 10",
	"label .f.form.la -text Amount",
	"entry .f.form.a -width 8",
	"label .f.form.lx -text Desc",
	"entry .f.form.x -width 24",
	"pack .f.form.ld .f.form.d .f.form.lc .f.form.c .f.form.lk .f.form.k .f.form.la .f.form.a .f.form.lx .f.form.x -side left -padx 2",
	"listbox .f.lb -width 92 -height 14 -selectmode browse",
	"scrollbar .f.sb -command {.f.lb yview}",
	"frame .f.lbf",
	"pack .f.lb -in .f.lbf -side left -fill both -expand 1",
	"pack .f.sb -in .f.lbf -side right -fill y",
	"frame .f.b",
	"button .f.b.add -text Add -command {send cmd add}",
	"button .f.b.del -text Delete -command {send cmd del}",
	"button .f.b.save -text Save -command {send cmd save}",
	"button .f.b.load -text Load -command {send cmd load}",
	"button .f.b.quit -text Quit -command {send cmd quit}",
	"pack .f.b.add .f.b.del .f.b.save .f.b.load .f.b.quit -side left -padx 4",
	"label .f.h -text {Add/Delete/Save/Load · view acct updates balance · q quit}",
	"pack .f.gap .f.v .f.form .f.lbf .f.b .f.h -side top -anchor w -pady 2",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	daytime = load Daytime Daytime->PATH;
	env = load Env Env->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	datafile = pickfile();
	entries = nil;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Budget", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, ".f.v.e insert 0 BANK");
	cmd(top, ".f.form.d insert 0 {"+today()+"}");
	loadfile();
	refresh();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		if(s == 16r1b || s == 'q' || s == 'Q')
			exit;
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		case c {
		"add" =>
			addentry();
		"del" =>
			delentry();
		"save" =>
			savefile();
		"load" =>
			loadfile();
		"quit" =>
			exit;
		}
	}
}

pickfile(): string
{
	tmp := "/tmp/temple-budget.txt";
	if(env == nil)
		return tmp;
	home := env->getenv("home");
	if(home == nil)
		return tmp;
	lib := home+"/lib";
	if(sys->open(lib, Sys->OREAD) == nil &&
	   sys->create(lib, Sys->OWRITE, Sys->DMDIR|8r775) == nil)
		return tmp;
	path := lib+"/temple-budget.txt";
	if(sys->create(path, Sys->OWRITE, 8r666) != nil)
		return path;
	return tmp;
}

today(): string
{
	return daytime->text(daytime->local(daytime->now()))[0:10];
}

addentry()
{
	d := cmd(top, ".f.form.d get");
	c := cmd(top, ".f.form.c get");
	k := cmd(top, ".f.form.k get");
	a := cmd(top, ".f.form.a get");
	x := cmd(top, ".f.form.x get");
	if(d == "" || c == "" || k == "" || a == ""){
		sys->fprint(sys->fildes(2), "budget: need date, accounts, amount\n");
		return;
	}
	amt := parseamt(a);
	if(amt < 0.0){
		sys->fprint(sys->fildes(2), "budget: bad amount %s\n", a);
		return;
	}
	e := ref Entry(d, c, k, amt, x);
	entries = insort(entries, e);
	cmd(top, ".f.form.d delete 0 end");
	cmd(top, ".f.form.d insert 0 {"+today()+"}");
	cmd(top, ".f.form.c delete 0 end");
	cmd(top, ".f.form.k delete 0 end");
	cmd(top, ".f.form.a delete 0 end");
	cmd(top, ".f.form.x delete 0 end");
	refresh();
}

insort(el: list of ref Entry, e: ref Entry): list of ref Entry
{
	if(el == nil)
		return e :: nil;
	if(e.date <= (hd el).date)
		return e :: el;
	return hd el :: insort(tl el, e);
}

parseamt(s: string): real
{
	(_n, v) := sys->tokenize(s, "\t \n");
	if(v == nil)
		return -1.0;
	return real hd v;
}

delentry()
{
	sel := cmd(top, ".f.lb curselection");
	if(sel == "" || sel == "-1")
		return;
	i := int sel;
	if(i < 0)
		return;
	j := 0;
	ne: list of ref Entry;
	for(el := entries; el != nil; el = tl el){
		if(j != i)
			ne = hd el :: ne;
		j++;
	}
	entries = revlist(ne);
	refresh();
}

revlist(l: list of ref Entry): list of ref Entry
{
	r: list of ref Entry;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

refresh()
{
	viewacct = cmd(top, ".f.v.e get");
	bal := 0.0;
	cmd(top, ".f.lb delete 0 end");
	i := 0;
	for(el := entries; el != nil; el = tl el){
		e := hd el;
		if(e.credit == viewacct)
			bal -= e.amount;
		if(e.debit == viewacct)
			bal += e.amount;
		line := sys->sprint("%s  %8s:%8.2f %8s  %s",
			e.date, e.credit, e.amount, e.debit, e.desc);
		cmd(top, sys->sprint(".f.lb insert %d {%s}", i, line));
		i++;
	}
	cmd(top, sys->sprint(".f.v.b configure -text {balance %8.2f}", bal));
	cmd(top, "update");
}

savefile()
{
	fd := sys->create(datafile, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "budget: cannot write %s: %r\n", datafile);
		return;
	}
	for(el := entries; el != nil; el = tl el){
		e := hd el;
		line := sys->sprint("%s\t%s\t%s\t%.2f\t%s\n",
			e.date, e.credit, e.debit, e.amount, e.desc);
		b := array of byte line;
		sys->write(fd, b, len b);
	}
}

loadfile()
{
	fd := sys->open(datafile, Sys->OREAD);
	if(fd == nil){
		entries = nil;
		refresh();
		return;
	}
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0){
		entries = nil;
		refresh();
		return;
	}
	entries = nil;
	s := string buf[0:n];
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		if(len ln == 0)
			continue;
		parts: list of string;
		field := "";
		for(k := 0; k < len ln; k++){
			if(ln[k] == '\t'){
				parts = field :: parts;
				field = "";
			}else
				field += string ln[k];
		}
		parts = field :: parts;
		if(len parts < 4)
			continue;
		# reverse parts list
		pl: list of string;
		for(p := parts; p != nil; p = tl p)
			pl = hd p :: pl;
		if(len pl < 4)
			continue;
		d := hd pl; pl = tl pl;
		cr := hd pl; pl = tl pl;
		db := hd pl; pl = tl pl;
		amt := parseamt(hd pl);
		desc := "";
		if(tl pl != nil)
			desc = hd tl pl;
		if(amt < 0.0)
			continue;
		entries = insort(entries, ref Entry(d, cr, db, amt, desc));
	}
	refresh();
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "budget tk: %s\n", e);
	return e;
}
