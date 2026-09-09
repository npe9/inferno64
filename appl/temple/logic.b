implement Logic;

# TempleOS Apps/Logic/Logic.HC — truth-table gate synthesizer.
#
# The original prompts in the console (gate preference order, table size,
# input columns A,B,C,... until blank, output columns until blank), fills
# the gate table by relaxation passes, then flips to a graphics screen and
# draws the circuit right-to-left: gate sprites, red connection wires,
# green input letters and "Dup" labels, black %04X value beside each node.
# This port keeps that flow inside a Tk form: the prompts become entries
# (space-separated values give the any-arity input/output lists; the gate
# entry keeps the user's preference ORDER, which matters because each pass
# tries gates in that order), the doc's "Pass : n" prints and progress bars
# become the message pane, and the schematic is drawn with the sprites
# rasterized from the original's DolDoc bins (icons/temple/logic_1..10 =
# $SP bins BI=1..10 = NOT..NOR3; Sprite3 blits bitmap bins in their stored
# colors, so they draw as extracted, not tinted).
#
# GAP: the schematic persists in the panel rather than being re-dumped into
# a scrolling document (Refresh(2,TRUE)/DocBottom has no Tk counterpart).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context, Display, Image, Font, Point, Rect: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;
include "grpalette.m";
	grpal: Grpalette;

Logic: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

GT_NULL: con 0;
GT_OUTPUT: con 1;
GT_INPUT: con 2;
GT_NOT: con 3;
GT_AND: con 4;
GT_OR: con 5;
GT_NAND: con 6;
GT_NOR: con 7;
GT_XOR: con 8;
GT_AND3: con 9;
GT_OR3: con 10;
GT_NAND3: con 11;
GT_NOR3: con 12;
GT_ENTRIES_NUM: con 13;

TABLE_SIZE_MAX: con 16r10000;
SEL_GATES_NUM: con 128;
MAXPASS: con 64;		# safety cap over the original's run-to-quiescence

CONNECT_WIDTH: con 16;
GATE_WIDTH: con 37;
FONT_WIDTH: con 8;

SCRW: con 640;
SCRH: con 480;

# exact TempleOS palette entries used by DrawDesign

gatenames := array[] of {
	"", "", "",
	"NOT", "AND", "OR", "NAND", "NOR", "XOR",
	"AND3", "OR3", "NAND3", "NOR3",
};

display: ref Display;
top: ref Toplevel;
buf: ref Image;
font: ref Font;
inkred, inkgreen, inkblack, inkwhite: ref Image;
sprimg := array[GT_ENTRIES_NUM] of ref Image;
sprmask := array[GT_ENTRIES_NUM] of ref Image;

tsize := 16r100;
gate: array of int;
in1, in2, in3: array of int;
displayed: array of int;
selgates := array[SEL_GATES_NUM] of int;
nsel := 0;
ninp := 0;
nout := 0;
outidx := -1;
passes := 0;
msgs := "";

cfg := array[] of {
	"frame .f",
	"label .f.tl -text {Truth-table gate synthesizer. All values are hex.}",
	"frame .f.sz",
	"label .f.sz.l -text {Table size (3 input=100, 4=10000):}",
	"entry .f.sz.e -width 8",
	"pack .f.sz.l .f.sz.e -side left -padx 4",
	"frame .f.in",
	"label .f.in.l -text {Input columns A B C ...:}",
	"entry .f.in.e -width 40",
	"pack .f.in.l .f.in.e -side left -padx 4",
	"frame .f.out",
	"label .f.out.l -text {Output columns:}",
	"entry .f.out.e -width 40",
	"pack .f.out.l .f.out.e -side left -padx 4",
	"frame .f.g",
	"label .f.g.l -text {Gates, in the order you prefer them used:}",
	"entry .f.g.e -width 44",
	"pack .f.g.l .f.g.e -side left -padx 4",
	"frame .f.b",
	"button .f.b.run -text {Run synthesis} -command {send cmd run}",
	"label .f.b.h -text {For example, enter A=0xF0, B=0xCC and C=0xAA. · q quit}",
	"pack .f.b.run .f.b.h -side left -padx 8",
	"text .f.t -width 78 -height 4 -state disabled",
	"panel .f.p -bd 1 -relief sunken",
	"pack .f.tl .f.sz .f.in .f.out .f.g .f.b .f.t -side top -anchor w -pady 2",
	"pack .f.p -side top -anchor w",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Logic", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, ".f.sz.e insert 0 100");
	cmd(top, ".f.in.e insert 0 {F0 CC AA}");
	cmd(top, ".f.g.e insert 0 {NOT AND OR NAND NOR XOR AND3 OR3 NAND3 NOR3}");

	font = Font.open(display, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(display, "*default*");
	inkred = display.color(grpal->value(Grpalette->RED));
	inkgreen = display.color(grpal->value(Grpalette->GREEN));
	inkblack = display.color(grpal->value(Grpalette->BLACK));
	inkwhite = display.color(grpal->value(Grpalette->WHITE));
	for(t := GT_NOT; t <= GT_NOR3; t++){
		# $SP bins BI=1..10 in Logic.HC, imgs[GT_NOT..GT_NOR3]
		sprimg[t] = display.open(sys->sprint("/icons/temple/logic_%d.bit", t-2));
		sprmask[t] = display.open(sys->sprint("/icons/temple/logic_%d.mask", t-2));
	}
	buf = display.newimage(Rect((0, 0), (SCRW, SCRH)), display.image.chans, 0, Draw->White);
	if(buf != nil)
		tk->putimage(top, ".f.p", buf, nil);
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
		if(c == "run")
			run();
	}
}

run()
{
	msgs = "";

	# table size: GetI64("Table size in hex (3 input=0x100,4=0x10000)")
	tsize = parsehex(cmd(top, ".f.sz.e get"));
	if(tsize < 1){
		show("No table specified, aborting.\n");
		return;
	}
	if(tsize > TABLE_SIZE_MAX){
		show("Too large\n");
		return;
	}
	# Init prints one example or the other, chosen by the table size
	show("\nEnter the hex truth table column values of inputs.\n");
	eg := "For example, enter A=0xF0, B=0xCC and C=0xAA.";
	if(tsize > 16r100)
		eg = "For example, enter A=0xFF00, B=0xF0F0, C=0xCCCC and D=0xAAAA.";
	show(eg + "\n");
	cmd(top, ".f.b.h configure -text {" + eg + " · q quit}");
	gate = array[tsize] of { * => GT_NULL };
	in1 = array[tsize] of int;
	in2 = array[tsize] of int;
	in3 = array[tsize] of int;
	ninp = 0;
	nout = 0;
	outidx = -1;

	# GetGates: gate types in the order the user prefers them used
	nsel = 0;
	(nil, gtoks) := sys->tokenize(cmd(top, ".f.g.e get"), " \t,");
	for(gl := gtoks; gl != nil; gl = tl gl){
		g := gatebyname(hd gl);
		if(g < 0){
			show(sys->sprint("Invalid gate: %s\n", hd gl));
			return;
		}
		if(nsel < SEL_GATES_NUM)
			selgates[nsel++] = g;
	}
	if(nsel == 0){
		show("No gates specified, aborting.\n");
		return;
	}

	# inputs: any number of columns, A, B, C, ...
	(nil, itoks) := sys->tokenize(cmd(top, ".f.in.e get"), " \t,");
	for(il := itoks; il != nil; il = tl il){
		v := parsehex(hd il);
		if(v < 0){
			show(sys->sprint("Bad input value: %s\n", hd il));
			return;
		}
		if(v >= tsize)
			app("Too large\n");
		else if(gate[v] != GT_NULL)
			app("Duplicate\n");
		else{
			gate[v] = GT_INPUT;
			in1[v] = ninp++;
		}
	}
	if(ninp == 0){
		show("No inputs specified, aborting.\n");
		return;
	}

	# outputs: any number of columns
	(nil, otoks) := sys->tokenize(cmd(top, ".f.out.e get"), " \t,");
	for(ol := otoks; ol != nil; ol = tl ol){
		v := parsehex(hd ol);
		if(v < 0){
			show(sys->sprint("Bad output value: %s\n", hd ol));
			return;
		}
		if(v >= tsize)
			app("Too large\n");
		else if(gate[v] == GT_INPUT)
			app(sys->sprint("To produce output %04X, connect to input %c\n",
				v, 'A'+in1[v]));
		else if(gate[v] == GT_OUTPUT)
			app("Duplicate\n");
		else{
			gate[v] = GT_OUTPUT;
			in1[v] = nout++;
		}
	}
	if(nout == 0){
		show("No output specified, aborting.\n");
		return;
	}

	found := synth();
	if(found > 0){
		drawit();
		app(sys->sprint("Found %d/%d outputs in %d passes.\n",
			found, nout, passes-1));
	}else
		app(sys->sprint("No design found (0/%d outputs).\n", nout));
}

gatebyname(s: string): int
{
	u := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'a' && c <= 'z')
			c += 'A' - 'a';
		u[len u] = c;
	}
	for(t := GT_NOT; t <= GT_NOR3; t++)
		if(u == gatenames[t])
			return t;
	return -1;
}

parsehex(s: string): int
{
	(nil, tok) := sys->tokenize(s, " \t");
	if(tok == nil)
		return -1;
	t := hd tok;
	if(len t > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X'))
		t = t[2:];
	if(len t == 0 || len t > 5)
		return -1;
	n := 0;
	for(i := 0; i < len t; i++){
		c := t[i];
		d := -1;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			return -1;
		n = (n << 4) | d;
	}
	return n;
}

# FillGateTable: relaxation passes; each pass tries the selected gates
# in preference order until every requested output has been produced or
# a pass changes nothing.
synth(): int
{
	found := 0;
	passes = 1;
	outidx = -1;
	chged := 1;
	added: array of int;

	while(found < nout && chged && passes <= MAXPASS){
		app(sys->sprint("Pass : %d\n", passes));
		passes++;
		chged = 0;
		added = array[tsize] of { * => 0 };
		ch: int;
		for(gi := 0; gi < nsel && found < nout; gi++){
			case selgates[gi] {
			GT_NOT =>
				(ch, found) = fillnot(added, found);
			GT_AND or GT_OR or GT_NAND or GT_NOR or GT_XOR =>
				(ch, found) = fill2(selgates[gi], added, found);
			GT_AND3 or GT_OR3 or GT_NAND3 or GT_NOR3 =>
				(ch, found) = fill3(selgates[gi], added, found);
			* =>
				ch = 0;
			}
			if(ch)
				chged = 1;
		}
	}
	return found;
}

usable(i: int, added: array of int): int
{
	return gate[i] > GT_OUTPUT && !added[i];
}

# record a newly reachable table slot; returns updated found count
place(t, j, i1, i2, i3, old: int, added: array of int, found: int): int
{
	gate[j] = t;
	in1[j] = i1;
	in2[j] = i2;
	in3[j] = i3;
	added[j] = 1;
	if(old == GT_OUTPUT){
		if(outidx < 0)
			outidx = j;
		found++;
	}
	return found;
}

fillnot(added: array of int, found: int): (int, int)
{
	ch := 0;
	mask := tsize - 1;
	for(i := 0; i < tsize; i++){
		if(!usable(i, added))
			continue;
		progress(i);
		j := (~i) & mask;
		old := gate[j];
		if(old >= GT_INPUT)
			continue;
		found = place(GT_NOT, j, i, 0, 0, old, added, found);
		ch = 1;
	}
	return (ch, found);
}

# FillAnd/FillOr/FillNAnd/FillNOr/FillXor: identical scan, different op
fill2(t: int, added: array of int, found: int): (int, int)
{
	ch := 0;
	mask := tsize - 1;
	for(i := 0; i < tsize; i++){
		if(!usable(i, added))
			continue;
		progress(i);
		for(k := 0; k < tsize; k++){
			if(!usable(k, added))
				continue;
			j: int;
			case t {
			GT_AND =>	j = i & k;
			GT_OR =>	j = i | k;
			GT_NAND =>	j = ~(i & k);
			GT_NOR =>	j = ~(i | k);
			* =>		j = i ^ k;
			}
			j &= mask;
			old := gate[j];
			if(old >= GT_INPUT)
				continue;
			found = place(t, j, i, k, 0, old, added, found);
			ch = 1;
		}
	}
	return (ch, found);
}

# FillAnd3/FillOr3/FillNAnd3/FillNOr3: triple-nested scan
fill3(t: int, added: array of int, found: int): (int, int)
{
	ch := 0;
	mask := tsize - 1;
	for(i := 0; i < tsize; i++){
		if(!usable(i, added))
			continue;
		progress(i);
		for(k := 0; k < tsize; k++){
			if(!usable(k, added))
				continue;
			for(l := 0; l < tsize; l++){
				if(!usable(l, added))
					continue;
				j: int;
				case t {
				GT_AND3 =>	j = i & k & l;
				GT_OR3 =>	j = i | k | l;
				GT_NAND3 =>	j = ~(i & k & l);
				* =>		j = ~(i | k | l);
				}
				j &= mask;
				old := gate[j];
				if(old >= GT_INPUT)
					continue;
				found = place(t, j, i, k, l, old, added, found);
				ch = 1;
			}
		}
	}
	return (ch, found);
}

# progress1/progress1_max counterpart: coarse position report during a pass
progress(i: int)
{
	if(i != 0 && (i & 16rFFF) == 0){
		cmd(top, sys->sprint(".f.b.h configure -text {pass %d: %04X/%04X}",
			passes-1, i, tsize));
		cmd(top, "update");
	}
}

# DrawIt/DrawDesign: the schematic.  Laid out right-to-left by pass count,
# gate sprites at each node, red wires from input stubs to children,
# green input letters and Dup labels, black %04X value beside every node.
drawit()
{
	if(buf == nil)
		return;
	buf.draw(buf.r, inkwhite, nil, Point(0, 0));
	displayed = array[tsize] of { * => 0 };
	drawdesign(0, outidx, 0);
	tk->putimage(top, ".f.p", buf, nil);
	cmd(top, sys->sprint(".f.b.h configure -text {found in %d passes · q quit}", passes-1));
	cmd(top, ".f.p dirty; update");
}

drawdesign(y, out, depth: int): (int, int, int)
{
	t := gate[out];
	xx := (passes-depth) * (GATE_WIDTH+CONNECT_WIDTH);
	yy := y;
	x1 := 0; y1 := 0;
	x2 := 0; y2 := 0;
	x3 := 0; y3 := 0;
	if(displayed[out] && t != GT_INPUT){
		grprint(inkgreen, xx-FONT_WIDTH*3, y-4, "Dup");
		y += 10;
	}else case t {
	GT_INPUT =>
		grprint(inkgreen, xx-FONT_WIDTH-4, y-4,
			sys->sprint("%c", 'A'+in1[out]));
		y += 10;
	GT_NOT =>
		y += 16;
		(y, x1, y1) = drawdesign(y, in1[out], depth+1);
		yy = y1;
		sprite(t, xx, yy);
		wire(xx-GATE_WIDTH, yy, x1, y1);
	GT_AND or GT_OR or GT_NAND or GT_NOR or GT_XOR =>
		y += 24;
		(y, x1, y1) = drawdesign(y, in1[out], depth+1);
		(y, x2, y2) = drawdesign(y, in2[out], depth+1);
		yy = (y1+y2)/2;
		sprite(t, xx, yy);
		wire(xx-GATE_WIDTH, yy-4, x1, y1);
		wire(xx-GATE_WIDTH, yy+4, x2, y2);
	GT_AND3 or GT_OR3 or GT_NAND3 or GT_NOR3 =>
		y += 32;
		(y, x1, y1) = drawdesign(y, in1[out], depth+1);
		(y, x2, y2) = drawdesign(y, in2[out], depth+1);
		(y, x3, y3) = drawdesign(y, in3[out], depth+1);
		yy = (y1+y2+y3)/3;
		sprite(t, xx, yy);
		wire(xx-GATE_WIDTH, yy-8, x1, y1);
		wire(xx-GATE_WIDTH, yy, x2, y2);
		wire(xx-GATE_WIDTH, yy+8, x3, y3);
	}
	grprint(inkblack, xx, yy+3, sys->sprint("%04X", out));
	displayed[out] = 1;
	return (y, xx, yy);
}

sprite(t, x, y: int)
{
	s := sprimg[t];
	if(s == nil){
		grprint(inkblack, x-GATE_WIDTH, y-4, gatenames[t]);
		return;
	}
	buf.draw(s.r.addpt(Point(x, y)), s, sprmask[t], s.r.min);
}

wire(x1, y1, x2, y2: int)
{
	buf.line(Point(x1, y1), Point(x2, y2),
		Draw->Endsquare, Draw->Endsquare, 0, inkred, Point(0, 0));
}

grprint(ink: ref Image, x, y: int, s: string)
{
	if(font != nil)
		buf.text(Point(x, y), ink, Point(0, 0), font, s);
}

show(msg: string)
{
	msgs = msg;
	setmsgs();
}

app(msg: string)
{
	msgs += msg;
	setmsgs();
}

setmsgs()
{
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	cmd(top, ".f.t insert end {"+msgs+"}");
	cmd(top, ".f.t see end");
	cmd(top, ".f.t configure -state disabled");
	cmd(top, "update");
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "logic tk: %s\n", e);
	return e;
}
