implement Budget;

# TempleOS Apps/Budget — DolDoc budget ledger, rebuilt over Tk.
# Faithful features: named accounts with 16-color palette colors, rows
# colored by credit account, per-row running balance for the view account,
# periodic templates (Interval/Monthly/Bimonthly/Semiannual/Annual) with
# BE_TEMPLATE_COPY rows, materialize-periodic ('p', first occurrence
# skipped), edit-in-place (Enter), copy ('c'), delete (Ctrl-Y) purging a
# template's copies, account picker popups (auto-offered on blank
# credit/debit, 'v' for the view account), accounts editor ('a'),
# File/Edit/View menus, CDate-sorted dates with "["/"]"/"*" and
# two-digit-year >2050 windowing, auto-save on exit (File->Abort skips it).
# GAP: DolDoc PopUpForm/PopUpMenu are rendered as Tk strips/panels
#      (Ok/Enter submits instead of Esc); Shift-Esc abort-without-save is
#      File->Abort, since the kbd channel cannot distinguish Shift-Esc.
# GAP: 'a' edits a simple "color name" list panel, not Accts.DD.Z in the
#      system editor; persistence is TSV, not Bgt.DATA.Z/Strs.DD.Z binary.

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

include "keyboard.m";

Budget: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# entry types (CBgtEntry.type)
BENORMAL: con 0;
BETEMPLATECOPY: con 4;

# template types (CBgtTemplate.type)
BTINTERVAL: con 1;
BTMONTHLY: con 2;
BTBIMONTHLY: con 3;
BTSEMIANNUAL: con 4;
BTANNUAL: con 5;

# UI modes
MLEDGER: con 0;
MPICK: con 1;
MACCTS: con 2;

# what completing the entry form does
PADD: con 0;		# insert new entry ('n'/'c')
PEDIT: con 1;		# replace ptarget (Enter on a normal row)
PTNEW: con 2;		# new template ('t')
PTEDIT: con 3;		# replace pttarget (Enter on a template-copy row)
PPERIODIC: con 4;	# expand once into real entries ('p')

# which field the account picker fills
PICKCREDIT: con 0;
PICKDEBIT: con 1;
PICKVIEW: con 2;

Entry: adt {
	serial: int;		# day number (CDate integer part equivalent)
	typ: int;		# BENORMAL or BETEMPLATECOPY
	credit: string;
	debit: string;
	amount: real;
	desc: string;
	tmpl: int;		# owning template id, or -1
};

Template: adt {
	id: int;
	ttype: int;		# BT*
	startdate: string;
	enddate: string;
	period: real;		# days, BT_INTERVAL only
	bserial: int;		# prototype entry date
	credit: string;
	debit: string;
	amount: real;
	desc: string;
};

Acct: adt {
	name: string;
	color: int;		# TempleOS palette index 0..15
};

# the exact TempleOS 16-color palette, index = TempleOS color
pal := array[] of {
	"#000000", "#0000AA", "#00AA00", "#00AAAA",
	"#AA0000", "#AA00AA", "#AA5500", "#AAAAAA",
	"#555555", "#5555FF", "#55FF55", "#55FFFF",
	"#FF5555", "#FF55FF", "#FFFF55", "#FFFFFF",
};

top: ref Toplevel;
entries: list of ref Entry;	# date-sorted, includes template copies
templates: list of ref Template;	# append order
accts: list of ref Acct;	# append order
nexttmplid := 1;
viewacct := "BANK";
datafile: string;

mode := MLEDGER;
rows: array of ref Entry;
selrow := 0;

pending := PADD;
ptarget: ref Entry;
pttarget: ref Template;
tmplactive := 0;

pickfor := PICKVIEW;
pickrows: array of ref Acct;
picksel := 0;

FN: con "/fonts/temple/temple.font";

cfg := array[] of {
	"frame .f -bg #FFFFFF",
	# menu bar
	"frame .f.mb -bg #AAAAAA",
	"menubutton .f.mb.file -text File -menu .mfile -font " + FN + " -bg #AAAAAA -fg #000000",
	"menubutton .f.mb.edit -text Edit -menu .medit -font " + FN + " -bg #AAAAAA -fg #000000",
	"menubutton .f.mb.view -text View -menu .mview -font " + FN + " -bg #AAAAAA -fg #000000",
	"label .f.mb.va -text {View:BANK} -font " + FN + " -bg #AAAAAA -fg #0000AA",
	"label .f.mb.st -text {} -font " + FN + " -bg #AAAAAA -fg #AA0000",
	"pack .f.mb.file .f.mb.edit .f.mb.view -side left -padx 4",
	"pack .f.mb.va -side left -padx 12",
	"pack .f.mb.st -side left -padx 8",
	"menu .mfile -font " + FN,
	".mfile add command -label {Abort (no save)} -command {send cmd abort}",
	".mfile add command -label {Exit (Esc)} -command {send cmd exit}",
	"menu .medit -font " + FN,
	".medit add command -label {NewEntry (n)} -command {send cmd new}",
	".medit add command -label {CopyEntry (c)} -command {send cmd copy}",
	".medit add command -label {PeriodicEntry (p)} -command {send cmd periodic}",
	".medit add command -label {EditEntry (Enter)} -command {send cmd edit}",
	".medit add command -label {DeleteEntry (Ctrl-Y)} -command {send cmd del}",
	".medit add command -label {NewTemplate (t)} -command {send cmd tmpl}",
	".medit add command -label {AcctsFile (a)} -command {send cmd accts}",
	"menu .mview -font " + FN,
	".mview add command -label {ViewAcct (v)} -command {send cmd viewacct}",
	# template strip (packed only during template flows)
	"frame .f.tf -bg #FFFFFF",
	"label .f.tf.lt -text {Type:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"choicebutton .f.tf.type -values {Interval Monthly Bimonthly Semiannual Annual} -variable ttype -font " + FN,
	"label .f.tf.ls -text {StartDate:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.tf.s -width 90 -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.tf.le -text {EndDate:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.tf.e -width 90 -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.tf.lp -text {Period:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.tf.p -width 60 -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.tf.h -text {[=first ]=last *=today} -font " + FN + " -bg #FFFFFF -fg #555555",
	"pack .f.tf.lt .f.tf.type .f.tf.ls .f.tf.s .f.tf.le .f.tf.e .f.tf.lp .f.tf.p .f.tf.h -side left -padx 2",
	# entry form strip (CBgtEntryForm field order: Date, Amount, Credit, Debit, Desc)
	"frame .f.f1 -bg #FFFFFF",
	"label .f.f1.ld -text {Date:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.f1.d -width 90 -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.f1.la -text {Amount:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.f1.a -width 80 -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.f1.lc -text {Credit(from)Acct:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.f1.c -width 80 -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.f1.lk -text {Debit(to)Acct:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.f1.k -width 80 -font " + FN + " -bg #FFFFFF -fg #000000",
	"pack .f.f1.ld .f.f1.d .f.f1.la .f.f1.a .f.f1.lc .f.f1.c .f.f1.lk .f.f1.k -side left -padx 2",
	"frame .f.f2 -bg #FFFFFF",
	"label .f.f2.lx -text {Desc:} -font " + FN + " -bg #FFFFFF -fg #000000",
	"entry .f.f2.x -width 260 -font " + FN + " -bg #FFFFFF -fg #000000",
	"button .f.f2.ok -text {Ok} -command {send cmd ok} -font " + FN,
	"button .f.f2.cancel -text {Cancel} -command {send cmd cancel} -font " + FN,
	"label .f.f2.mode -text {NewEntry} -font " + FN + " -bg #FFFFFF -fg #0000AA",
	"pack .f.f2.lx .f.f2.x .f.f2.ok .f.f2.cancel .f.f2.mode -side left -padx 2",
	# ledger
	"frame .f.lbf -bg #FFFFFF",
	"text .f.t -width 664 -height 336 -state disabled -wrap none -bg #FFFFFF -fg #000000 -font " + FN + " -yscrollcommand {.f.sb set}",
	"scrollbar .f.sb -command {.f.t yview}",
	"pack .f.sb -in .f.lbf -side right -fill y",
	"pack .f.t -in .f.lbf -side left -fill both -expand 1",
	# account picker panel (swapped in for the ledger)
	"frame .f.pick -bg #FFFFFF",
	"label .f.pick.l -text {} -font " + FN + " -bg #FFFFFF -fg #000000",
	"text .f.pick.t -width 300 -height 260 -state disabled -wrap none -bg #FFFFFF -fg #000000 -font " + FN,
	"pack .f.pick.l -side top -anchor w -pady 2",
	"pack .f.pick.t -side top -anchor w -fill both -expand 1",
	# accounts editor panel (swapped in for the ledger)
	"frame .f.acct -bg #FFFFFF",
	"label .f.acct.l1 -text {Set the name and color of your accounts.} -font " + FN + " -bg #FFFFFF -fg #000000",
	"label .f.acct.l2 -text {One per line: color(0-15) name. Delete a line to remove an account.} -font " + FN + " -bg #FFFFFF -fg #00AA00",
	"text .f.acct.t -width 300 -height 240 -wrap none -bg #FFFFFF -fg #000000 -font " + FN,
	"frame .f.acct.b -bg #FFFFFF",
	"button .f.acct.b.ok -text {Ok} -command {send cmd aok} -font " + FN,
	"button .f.acct.b.cancel -text {Cancel} -command {send cmd acancel} -font " + FN,
	"pack .f.acct.b.ok .f.acct.b.cancel -side left -padx 4",
	"pack .f.acct.l1 .f.acct.l2 -side top -anchor w",
	"pack .f.acct.t -side top -anchor w -fill both -expand 1",
	"pack .f.acct.b -side top -anchor w -pady 2",
	# bindings
	"bind .f.t <ButtonRelease-1> {send cmd lclick %x %y}",
	"bind .f.pick.t <ButtonRelease-1> {send cmd pclick %x %y}",
	"bind .f.f1.d <Key-\n> {send cmd ok}",
	"bind .f.f1.a <Key-\n> {send cmd ok}",
	"bind .f.f1.c <Key-\n> {send cmd ok}",
	"bind .f.f1.k <Key-\n> {send cmd ok}",
	"bind .f.f2.x <Key-\n> {send cmd ok}",
	"bind .f.tf.s <Key-\n> {send cmd ok}",
	"bind .f.tf.e <Key-\n> {send cmd ok}",
	"bind .f.tf.p <Key-\n> {send cmd ok}",
	# main layout (.f.tf appears only during template flows)
	"pack .f.mb -side top -fill x",
	"pack .f.f1 .f.f2 -side top -anchor w -pady 1",
	"pack .f.lbf -side top -fill both -expand 1",
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
	cmd(top, "variable ttype 0");
	for(i = 0; i < 16; i++){
		cmd(top, sys->sprint(".f.t tag configure c%d -foreground %s", i, pal[i]));
		cmd(top, sys->sprint(".f.pick.t tag configure c%d -foreground %s", i, pal[i]));
	}
	cmd(top, ".f.t tag configure sel -background #AAAAAA");
	cmd(top, ".f.pick.t tag configure sel -background #AAAAAA");
	cmd(top, ".f.f1.d insert 0 *");
	loadfile();
	if(accts == nil)
		seedaccts();
	expandall();
	regen();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	c := <-top.ctxt.kbd =>
		if(!dokey(c))
			tk->keyboard(top, c);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		if(s == "exit")
			savefile();	# original writes Bgt.DATA.Z etc. when the viewer exits
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		docmd(c);
	}
}

# ---------- keyboard ----------

dokey(c: int): int
{
	if(mode == MPICK){
		case c {
		Keyboard->Up =>
			if(picksel > 0)
				setpicksel(picksel-1);
		Keyboard->Down =>
			if(picksel < len pickrows - 1)
				setpicksel(picksel+1);
		'\n' =>
			choosepick();
		16r1b =>
			endpick();
		}
		return 1;	# swallow everything while picking
	}
	if(mode == MACCTS){
		if(c == 16r1b){
			endaccts();
			return 1;
		}
		return 0;	# let typing reach the editor text
	}
	f := cmd(top, "focus");
	if(prefix(".f.f1.", f) || prefix(".f.f2.", f) || prefix(".f.tf.", f)){
		if(c == 16r1b){
			cancelform();
			return 1;
		}
		return 0;	# typing goes to the form fields
	}
	case c {
	'n' =>
		startentryform(nil, PADD, nil);
	'c' =>
		startentryform(currow(), PADD, nil);
	'p' =>
		doperiodic();
	't' =>
		starttmplform(nil, nil, PTNEW);
	'a' =>
		startaccts();
	'v' =>
		startpick("View Acct", PICKVIEW);
	'\n' =>
		doedit();
	25 =>		# Ctrl-Y: delete entry / whole template
		dodel();
	Keyboard->Up =>
		if(selrow > 0)
			setsel(selrow-1);
	Keyboard->Down =>
		if(selrow < len rows - 1)
			setsel(selrow+1);
	16r1b or 'q' =>	# Esc exits the viewer, saving (Shift-Esc abort = File menu)
		savefile();
		exit;
	* =>
		return 0;
	}
	return 1;
}

docmd(c: string)
{
	(n, toks) := sys->tokenize(c, " ");
	if(n < 1)
		return;
	case hd toks {
	"new" =>
		startentryform(nil, PADD, nil);
	"copy" =>
		startentryform(currow(), PADD, nil);
	"periodic" =>
		doperiodic();
	"edit" =>
		doedit();
	"del" =>
		dodel();
	"tmpl" =>
		starttmplform(nil, nil, PTNEW);
	"accts" =>
		startaccts();
	"viewacct" =>
		startpick("View Acct", PICKVIEW);
	"ok" =>
		submit();
	"cancel" =>
		cancelform();
	"aok" =>
		acctsok();
	"acancel" =>
		endaccts();
	"abort" =>
		exit;	# Shift-Esc equivalent: no save
	"exit" =>
		savefile();
		exit;
	"lclick" =>
		if(n >= 3)
			lclick(int hd tl toks, int hd tl tl toks);
	"pclick" =>
		if(n >= 3)
			pclick(int hd tl toks, int hd tl tl toks);
	}
}

# ---------- dates (CDate work-alike: serial day number) ----------

jdn(y, m, d: int): int
{
	a := (14 - m) / 12;
	y2 := y + 4800 - a;
	m2 := m + 12*a - 3;
	return d + (153*m2 + 2)/5 + 365*y2 + y2/4 - y2/100 + y2/400 - 32045;
}

fromjdn(j: int): (int, int, int)
{
	a := j + 32044;
	b := (4*a + 3) / 146097;
	c := a - 146097*b/4;
	d := (4*c + 3) / 1461;
	e := c - 1461*d/4;
	m := (5*e + 2) / 153;
	return (100*b + d - 4800 + m/10, m + 3 - 12*(m/10), e - (153*m + 2)/5 + 1);
}

todayserial(): int
{
	tm := daytime->local(daytime->now());
	return jdn(tm.year + 1900, tm.mon + 1, tm.mday);
}

fmtdate(serial: int): string
{
	(y, m, d) := fromjdn(serial);
	return sys->sprint("%02d/%02d/%02d", m, d, y % 100);
}

fmtdate4(serial: int): string
{
	(y, m, d) := fromjdn(serial);
	return sys->sprint("%02d/%02d/%04d", m, d, y);
}

firstserial(): int
{
	if(entries != nil)
		return (hd entries).serial;
	return todayserial();	# b_head.date=Now
}

lastserial(): int
{
	s := todayserial();
	for(el := entries; el != nil; el = tl el)
		s = (hd el).serial;
	return s;
}

contains(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

numval(s: string): int
{
	if(s == "")
		return -1;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return -1;
	return int s;
}

# MyStr2Date: "["=first entry, "]"=last entry, ""/"*"=today,
# two-digit years are 20xx then windowed back a century if > 2050.
parsedate(s: string): int
{
	s = trim(s);
	if(s == "" || s == "*")
		return todayserial();
	if(contains(s, '['))
		return firstserial();
	if(contains(s, ']'))
		return lastserial();
	(n, parts) := sys->tokenize(s, "/-.");
	if(n != 3)
		return todayserial();
	m := numval(hd parts);
	d := numval(hd tl parts);
	y := numval(hd tl tl parts);
	if(m < 1 || m > 12 || d < 1 || d > 31 || y < 0)
		return todayserial();
	if(y < 100)
		y += 2000;
	if(y > 2050)
		y -= 100;
	return jdn(y, m, d);
}

floorint(r: real): int
{
	i := int r;	# Limbo rounds to nearest
	if(real i > r)
		i--;
	return i;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	return s[i:j];
}

detab(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '\t' || s[i] == '\n')
			r[len r] = ' ';
		else
			r[len r] = s[i];
	return r;
}

# ---------- entries, templates, accounts ----------

# BgtIns: insert before the first entry dated >= the new one
insort(el: list of ref Entry, e: ref Entry): list of ref Entry
{
	if(el == nil)
		return e :: nil;
	if(e.serial <= (hd el).serial)
		return e :: el;
	return hd el :: insort(tl el, e);
}

removeentry(e: ref Entry)
{
	ne: list of ref Entry;
	for(el := entries; el != nil; el = tl el)
		if(hd el != e)
			ne = hd el :: ne;
	entries = rev(ne);
}

rev(l: list of ref Entry): list of ref Entry
{
	r: list of ref Entry;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# BgtTemplatePurge
purge(id: int)
{
	ne: list of ref Entry;
	for(el := entries; el != nil; el = tl el){
		e := hd el;
		if(!(e.typ == BETEMPLATECOPY && e.tmpl == id))
			ne = e :: ne;
	}
	entries = rev(ne);
}

findtmpl(id: int): ref Template
{
	for(tt := templates; tt != nil; tt = tl tt)
		if((hd tt).id == id)
			return hd tt;
	return nil;
}

deltmpl(t: ref Template)
{
	nt: list of ref Template;
	for(tt := templates; tt != nil; tt = tl tt)
		if(hd tt != t)
			nt = hd tt :: nt;
	templates = nil;
	for(; nt != nil; nt = tl nt)
		templates = hd nt :: templates;
}

# BgtTemplateExpand: periodic!=0 materializes real entries, skipping the
# first occurrence (it already exists as the row 'p' was invoked on).
expandtmpl(t: ref Template, periodic: int)
{
	start := parsedate(t.startdate);
	end := parsedate(t.enddate);
	first := 1;
	n := 0;
	case t.ttype {
	BTINTERVAL =>
		if(t.period <= 0.0)
			return;
		d := real start;
		while(d <= real end && n < 5000){
			if(!first || !periodic)
				emitcopy(t, floorint(d), periodic);
			d += t.period;
			first = 0;
			n++;
		}
	BTMONTHLY or BTBIMONTHLY or BTSEMIANNUAL or BTANNUAL =>
		step: int;
		case t.ttype {
		BTMONTHLY =>	step = 1;
		BTBIMONTHLY =>	step = 2;
		BTSEMIANNUAL =>	step = 6;
		* =>		step = 12;
		}
		(y, m, dom) := fromjdn(start);
		for(;;){
			d := jdn(y, m, dom);
			if(d > end || n >= 5000)
				break;
			if(!first || !periodic)
				emitcopy(t, d, periodic);
			m += step;
			while(m > 12){
				m -= 12;
				y++;
			}
			first = 0;
			n++;
		}
	}
}

emitcopy(t: ref Template, serial: int, periodic: int)
{
	e: ref Entry;
	if(periodic)
		e = ref Entry(serial, BENORMAL, t.credit, t.debit, t.amount, t.desc, -1);
	else
		e = ref Entry(serial, BETEMPLATECOPY, t.credit, t.debit, t.amount, t.desc, t.id);
	entries = insort(entries, e);
}

expandall()
{
	for(tt := templates; tt != nil; tt = tl tt)
		expandtmpl(hd tt, 0);
}

colorof(name: string): int
{
	for(al := accts; al != nil; al = tl al)
		if((hd al).name == name)
			return (hd al).color;
	return 0;	# BgtAcctColor: BLACK for unknown
}

# StrFileAdd: register an account name; new ones default to black
acctensure(name: string)
{
	if(name == "")
		return;
	for(al := accts; al != nil; al = tl al)
		if((hd al).name == name)
			return;
	addacct(name, 0);
}

addacct(name: string, color: int)
{
	na: list of ref Acct;
	for(al := accts; al != nil; al = tl al)
		na = hd al :: na;
	na = ref Acct(name, color) :: na;
	accts = nil;
	for(; na != nil; na = tl na)
		accts = hd na :: accts;
}

# default Accts.DD shipped with TempleOS (Install.HC copies it in)
seedaccts()
{
	addacct("JOB", 6);
	addacct("BANK", 1);
	addacct("CREDIT", 4);
	addacct("CASH", 2);
	addacct("RENT", 0);
	addacct("CAR", 0);
	addacct("UTILITIES", 0);
	addacct("MISC", 0);
	addacct("CLOTHS", 0);
	addacct("HEALTH", 0);
	addacct("CHARITY", 0);
}

# ---------- ledger display (BgtRegen) ----------

fixs(s: string, n: int): string
{
	if(len s > n)
		return s[0:n];
	while(len s < n)
		s += " ";
	return s;
}

regen()
{
	nrows := 0;
	for(el := entries; el != nil; el = tl el)
		nrows++;
	rows = array[nrows] of ref Entry;
	i := 0;
	for(el = entries; el != nil; el = tl el)
		rows[i++] = hd el;
	if(selrow >= nrows)
		selrow = nrows - 1;
	if(selrow < 0)
		selrow = 0;
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	bal := 0.0;
	for(i = 0; i < nrows; i++){
		e := rows[i];
		if(viewacct == e.credit)
			bal -= e.amount;
		if(viewacct == e.debit)
			bal += e.amount;
		# original line: "%D %8ts %8ts:%8.2f %8.2f:%s"
		line := fmtdate(e.serial) + " " + fixs(e.credit, 8) + " " + fixs(e.debit, 8) +
			":" + sys->sprint("%8.2f", bal) + " " + sys->sprint("%8.2f", e.amount) +
			":" + e.desc;
		cmd(top, ".f.t insert end " + tk->quote(line+"\n") + " c" + string colorof(e.credit));
	}
	cmd(top, ".f.t configure -state disabled");
	if(nrows > 0){
		l := string (selrow+1);
		cmd(top, ".f.t tag add sel "+l+".0 "+l+".end");
		cmd(top, ".f.t see "+l+".0");
	}
	cmd(top, ".f.mb.va configure -text " + tk->quote("View:"+viewacct));
	cmd(top, "update");
}

setsel(i: int)
{
	selrow = i;
	cmd(top, ".f.t tag remove sel 1.0 end");
	if(len rows > 0){
		l := string (selrow+1);
		cmd(top, ".f.t tag add sel "+l+".0 "+l+".end");
		cmd(top, ".f.t see "+l+".0");
	}
	cmd(top, "update");
}

currow(): ref Entry
{
	if(selrow >= 0 && selrow < len rows)
		return rows[selrow];
	return nil;
}

lclick(x, y: int)
{
	t := cmd(top, ".f.t index @" + string x + "," + string y);
	(n, l) := sys->tokenize(t, ".");
	if(n < 1)
		return;
	i := int hd l - 1;
	if(i >= 0 && i < len rows)
		setsel(i);
}

status(s: string)
{
	cmd(top, ".f.mb.st configure -text " + tk->quote(s));
	cmd(top, "update");
}

# ---------- entry / template forms ----------

setentry(w, s: string)
{
	cmd(top, w+" delete 0 end");
	if(s != "")
		cmd(top, w+" insert 0 " + tk->quote(s));
}

getentry(w: string): string
{
	return trim(cmd(top, w+" get"));
}

modelabel(): string
{
	case pending {
	PEDIT =>	return "EditEntry";
	PTNEW =>	return "NewTemplate";
	PTEDIT =>	return "EditTemplate";
	PPERIODIC =>	return "PeriodicEntry";
	}
	return "NewEntry";
}

startentryform(dft: ref Entry, pend: int, target: ref Entry)
{
	pending = pend;
	ptarget = target;
	if(dft != nil){
		setentry(".f.f1.d", fmtdate(dft.serial));
		setentry(".f.f1.a", sys->sprint("%.2f", dft.amount));
		setentry(".f.f1.c", dft.credit);
		setentry(".f.f1.k", dft.debit);
		setentry(".f.f2.x", dft.desc);
	}else{
		setentry(".f.f1.d", "*");
		setentry(".f.f1.a", "");
		setentry(".f.f1.c", "");
		setentry(".f.f1.k", "");
		setentry(".f.f2.x", "");
	}
	cmd(top, ".f.f2.mode configure -text {"+modelabel()+"}");
	status("");
	cmd(top, "focus .f.f1.d");
	cmd(top, "update");
}

showtmplstrip(show: int)
{
	if(show == tmplactive)
		return;
	tmplactive = show;
	if(show){
		cmd(top, "pack forget .f.f1 .f.f2 .f.lbf");
		cmd(top, "pack .f.tf .f.f1 .f.f2 -side top -anchor w -pady 1");
		cmd(top, "pack .f.lbf -side top -fill both -expand 1");
	}else
		cmd(top, "pack forget .f.tf");
	cmd(top, "update");
}

# BgtTemplatePmt defaults: type=Interval, start="[" (or the source row's
# date), end="]"; editing pre-fills from the template.
starttmplform(dftt: ref Template, dftb: ref Entry, pend: int)
{
	showtmplstrip(1);
	if(dftt != nil){
		cmd(top, "variable ttype "+string (dftt.ttype-1));
		setentry(".f.tf.s", dftt.startdate);
		setentry(".f.tf.e", dftt.enddate);
		setentry(".f.tf.p", sys->sprint("%g", dftt.period));
		startentryform(ref Entry(dftt.bserial, BENORMAL, dftt.credit, dftt.debit,
			dftt.amount, dftt.desc, -1), pend, nil);
		pttarget = dftt;
	}else{
		cmd(top, "variable ttype 0");
		if(dftb != nil)
			setentry(".f.tf.s", fmtdate(dftb.serial));
		else
			setentry(".f.tf.s", "[");
		setentry(".f.tf.e", "]");
		setentry(".f.tf.p", "");
		startentryform(dftb, pend, nil);
		pttarget = nil;
	}
}

cancelform()
{
	pending = PADD;
	ptarget = nil;
	pttarget = nil;
	showtmplstrip(0);
	setentry(".f.f1.d", "*");
	setentry(".f.f1.a", "");
	setentry(".f.f1.c", "");
	setentry(".f.f1.k", "");
	setentry(".f.f2.x", "");
	cmd(top, ".f.f2.mode configure -text {NewEntry}");
	status("");
	cmd(top, "focus .");
	cmd(top, "update");
}

parseamt(s: string): (int, real)
{
	s = trim(s);
	if(s == "")
		return (0, 0.0);
	digits := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= '0' && c <= '9')
			digits++;
		else if(!(c == '.' || c == '-' || c == '+' || c == ','))
			return (0, 0.0);
	}
	if(digits == 0)
		return (0, 0.0);
	return (1, real s);
}

# BgtEntryPmt/BgtTemplatePmt completion; blank credit/debit auto-offers
# the account picker, like the original form loop.
submit()
{
	credit := detab(getentry(".f.f1.c"));
	debit := detab(getentry(".f.f1.k"));
	ttype := 0;
	period := 0.0;
	if(tmplactive){
		ttype = int cmd(top, "variable ttype") + 1;
		(pok, pv) := parseamt(getentry(".f.tf.p"));
		period = pv;
		if(ttype == BTINTERVAL && (!pok || period <= 0.0)){
			status("Interval template needs Period > 0");
			return;
		}
	}
	if(credit == ""){
		startpick("Credit Acct", PICKCREDIT);
		return;
	}
	if(debit == ""){
		startpick("Debit Acct", PICKDEBIT);
		return;
	}
	(aok, amount) := parseamt(getentry(".f.f1.a"));
	if(!aok){
		status("bad amount");
		return;
	}
	serial := parsedate(getentry(".f.f1.d"));
	desc := detab(getentry(".f.f2.x"));
	acctensure(credit);
	acctensure(debit);
	case pending {
	PADD =>
		entries = insort(entries, ref Entry(serial, BENORMAL, credit, debit, amount, desc, -1));
	PEDIT =>
		if(ptarget != nil)
			removeentry(ptarget);
		entries = insort(entries, ref Entry(serial, BENORMAL, credit, debit, amount, desc, -1));
	PTNEW =>
		t := ref Template(nexttmplid++, ttype, getentry(".f.tf.s"),
			getentry(".f.tf.e"), period, serial, credit, debit, amount, desc);
		templates = apptmpl(templates, t);
		expandtmpl(t, 0);
	PTEDIT =>
		if(pttarget != nil){
			purge(pttarget.id);
			pttarget.ttype = ttype;
			pttarget.startdate = getentry(".f.tf.s");
			pttarget.enddate = getentry(".f.tf.e");
			pttarget.period = period;
			pttarget.bserial = serial;
			pttarget.credit = credit;
			pttarget.debit = debit;
			pttarget.amount = amount;
			pttarget.desc = desc;
			expandtmpl(pttarget, 0);
		}
	PPERIODIC =>
		t := ref Template(-1, ttype, getentry(".f.tf.s"),
			getentry(".f.tf.e"), period, serial, credit, debit, amount, desc);
		expandtmpl(t, 1);	# first occurrence skipped: it is the source row
	}
	cancelform();
	regen();
}

apptmpl(l: list of ref Template, t: ref Template): list of ref Template
{
	if(l == nil)
		return t :: nil;
	return hd l :: apptmpl(tl l, t);
}

# Enter: edit the current row in place; a template copy edits its template
doedit()
{
	e := currow();
	if(e == nil)
		return;
	if(e.typ == BETEMPLATECOPY){
		t := findtmpl(e.tmpl);
		if(t != nil)
			starttmplform(t, nil, PTEDIT);
	}else
		startentryform(e, PEDIT, e);
}

# Ctrl-Y: delete entry; on a template copy, delete the template + copies
dodel()
{
	e := currow();
	if(e == nil)
		return;
	if(e.typ == BETEMPLATECOPY){
		t := findtmpl(e.tmpl);
		if(t != nil){
			purge(t.id);
			deltmpl(t);
		}
	}else
		removeentry(e);
	regen();
}

# 'p': expand a template's schedule once into real entries, from this row
doperiodic()
{
	e := currow();
	if(e == nil)
		return;
	starttmplform(nil, e, PPERIODIC);
}

# ---------- account picker (BgtPopUpAcct) ----------

startpick(title: string, what: int)
{
	if(accts == nil){
		status("no accounts; use Edit->AcctsFile");
		return;
	}
	pickfor = what;
	n := 0;
	for(al := accts; al != nil; al = tl al)
		n++;
	pickrows = array[n] of ref Acct;
	i := 0;
	for(al = accts; al != nil; al = tl al)
		pickrows[i++] = hd al;
	dft := "";
	case what {
	PICKVIEW =>	dft = viewacct;
	PICKCREDIT =>	dft = getentry(".f.f1.c");
	PICKDEBIT =>	dft = getentry(".f.f1.k");
	}
	picksel = 0;
	for(i = 0; i < n; i++)
		if(pickrows[i].name == dft)
			picksel = i;
	cmd(top, ".f.pick.l configure -text " + tk->quote(title+"  (Enter=choose Esc=cancel)"));
	cmd(top, ".f.pick.t configure -state normal");
	cmd(top, ".f.pick.t delete 1.0 end");
	for(i = 0; i < n; i++)
		cmd(top, ".f.pick.t insert end " + tk->quote(pickrows[i].name+"\n") +
			" c" + string pickrows[i].color);
	cmd(top, ".f.pick.t configure -state disabled");
	cmd(top, "pack forget .f.lbf");
	cmd(top, "pack .f.pick -side top -fill both -expand 1");
	mode = MPICK;
	cmd(top, "focus .");
	setpicksel(picksel);
}

setpicksel(i: int)
{
	picksel = i;
	cmd(top, ".f.pick.t tag remove sel 1.0 end");
	if(len pickrows > 0){
		l := string (picksel+1);
		cmd(top, ".f.pick.t tag add sel "+l+".0 "+l+".end");
		cmd(top, ".f.pick.t see "+l+".0");
	}
	cmd(top, "update");
}

pclick(x, y: int)
{
	t := cmd(top, ".f.pick.t index @" + string x + "," + string y);
	(n, l) := sys->tokenize(t, ".");
	if(n < 1)
		return;
	i := int hd l - 1;
	if(i >= 0 && i < len pickrows){
		setpicksel(i);
		choosepick();
	}
}

choosepick()
{
	if(picksel < 0 || picksel >= len pickrows){
		endpick();
		return;
	}
	name := pickrows[picksel].name;
	endpick();
	case pickfor {
	PICKVIEW =>
		viewacct = name;
		regen();	# original 'v' regenerates immediately
	PICKCREDIT =>
		setentry(".f.f1.c", name);
		submit();	# re-enter the form loop, like PopUpForm
	PICKDEBIT =>
		setentry(".f.f1.k", name);
		submit();
	}
}

endpick()
{
	mode = MLEDGER;
	cmd(top, "pack forget .f.pick");
	cmd(top, "pack .f.lbf -side top -fill both -expand 1");
	cmd(top, "update");
}

# ---------- accounts editor ('a') ----------

startaccts()
{
	cmd(top, ".f.acct.t delete 1.0 end");
	for(al := accts; al != nil; al = tl al)
		cmd(top, ".f.acct.t insert end " +
			tk->quote(sys->sprint("%d %s\n", (hd al).color, (hd al).name)));
	cmd(top, "pack forget .f.lbf");
	cmd(top, "pack .f.acct -side top -fill both -expand 1");
	mode = MACCTS;
	cmd(top, "focus .f.acct.t");
	cmd(top, "update");
}

acctsok()
{
	s := cmd(top, ".f.acct.t get 1.0 end");
	na: list of ref Acct;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		ln := trim(hd lines);
		if(ln == "")
			continue;
		color := 0;
		name := ln;
		(n, toks) := sys->tokenize(ln, " \t");
		if(n >= 2 && numval(hd toks) >= 0){
			color = int hd toks % 16;
			name = trim(ln[len hd toks:]);
		}
		if(name != "")
			na = ref Acct(name, color) :: na;
	}
	accts = nil;
	for(; na != nil; na = tl na)
		accts = hd na :: accts;
	endaccts();
	regen();
}

endaccts()
{
	mode = MLEDGER;
	cmd(top, "pack forget .f.acct");
	cmd(top, "pack .f.lbf -side top -fill both -expand 1");
	cmd(top, "focus .");
	cmd(top, "update");
}

# ---------- persistence (TSV stand-in for Bgt.DATA.Z/Strs/Accts) ----------

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

savefile()
{
	fd := sys->create(datafile, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "budget: cannot write %s: %r\n", datafile);
		return;
	}
	out := "";
	for(al := accts; al != nil; al = tl al)
		out += sys->sprint("A\t%d\t%s\n", (hd al).color, (hd al).name);
	for(tt := templates; tt != nil; tt = tl tt){
		t := hd tt;
		out += sys->sprint("T\t%d\t%s\t%s\t%g\t%s\t%s\t%s\t%.2f\t%s\n",
			t.ttype, t.startdate, t.enddate, t.period,
			fmtdate4(t.bserial), t.credit, t.debit, t.amount, t.desc);
	}
	for(el := entries; el != nil; el = tl el){
		e := hd el;
		if(e.typ == BETEMPLATECOPY)
			continue;	# copies are regenerated from templates
		out += sys->sprint("E\t%s\t%s\t%s\t%.2f\t%s\n",
			fmtdate4(e.serial), e.credit, e.debit, e.amount, e.desc);
	}
	b := array of byte out;
	sys->write(fd, b, len b);
}

splitfields(ln: string): array of string
{
	nf := 1;
	for(i := 0; i < len ln; i++)
		if(ln[i] == '\t')
			nf++;
	f := array[nf] of string;
	for(i = 0; i < nf; i++)
		f[i] = "";
	j := 0;
	for(i = 0; i < len ln; i++)
		if(ln[i] == '\t')
			j++;
		else
			f[j][len f[j]] = ln[i];
	return f;
}

loadfile()
{
	entries = nil;
	templates = nil;
	accts = nil;
	fd := sys->open(datafile, Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[262144] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return;
	s := string buf[0:n];
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		if(len ln == 0 || ln[0] == '#')
			continue;
		f := splitfields(ln);
		case f[0] {
		"A" =>
			if(len f >= 3 && f[2] != "")
				addacct(f[2], int f[1] % 16);
		"T" =>
			if(len f >= 10){
				(ok, amt) := parseamt(f[8]);
				(pok, per) := parseamt(f[4]);
				if(ok && pok)
					templates = apptmpl(templates,
						ref Template(nexttmplid++, int f[1], f[2], f[3],
							per, parsedate(f[5]), f[6], f[7], amt, f[9]));
			}
		"E" =>
			if(len f >= 6){
				(ok, amt) := parseamt(f[4]);
				if(ok)
					entries = insort(entries,
						ref Entry(parsedate(f[1]), BENORMAL, f[2], f[3], amt, f[5], -1));
			}
		* =>
			# legacy port format: date credit debit amount desc
			if(len f >= 4){
				(ok, amt) := parseamt(f[3]);
				desc := "";
				if(len f >= 5)
					desc = f[4];
				if(ok)
					entries = insort(entries,
						ref Entry(parsedate(f[0]), BENORMAL, f[1], f[2], amt, desc, -1));
			}
		}
	}
	# register any accounts named only in entries/templates (BgtAcctsUpdate)
	for(el := entries; el != nil; el = tl el){
		acctensure((hd el).credit);
		acctensure((hd el).debit);
	}
	for(tt := templates; tt != nil; tt = tl tt){
		acctensure((hd tt).credit);
		acctensure((hd tt).debit);
	}
}

# ---------- misc ----------

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "budget tk: %s (%s)\n", e, s);
	return e;
}
