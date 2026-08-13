implement Logic;

# TempleOS Apps/Logic/Logic.HC — truth-table gate synthesizer (Tk)
# GAP: no gate sprites; max table 0x100 (not 0x10000); no 3-input gates

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

TABLESIZE: con 16r100;
MAXPASS: con 64;

top: ref Toplevel;
gate: array of int;
in1, in2: array of int;
selgates: array of int;
nsel := 0;
ninp := 0;
nout := 0;
outidx := -1;
passes := 0;

cfg := array[] of {
	"frame .f",
	"label .f.gap -fg #884400 -text {GAP: text tree only — table 0x100 · no gate sprites}",
	"label .f.tl -text {3-input truth table (size 0x100). Inputs A/B/C hex, outputs hex.}",
	"frame .f.in",
	"label .f.in.la -text {A=}",
	"entry .f.in.a -width 8",
	"label .f.in.lb -text {B=}",
	"entry .f.in.b -width 8",
	"label .f.in.lc -text {C=}",
	"entry .f.in.c -width 8",
	"pack .f.in.la .f.in.a .f.in.lb .f.in.b .f.in.lc .f.in.c -side left -padx 4",
	"frame .f.out",
	"label .f.out.l1 -text {Out1=}",
	"entry .f.out.o1 -width 8",
	"label .f.out.l2 -text {Out2=}",
	"entry .f.out.o2 -width 8",
	"pack .f.out.l1 .f.out.o1 .f.out.l2 .f.out.o2 -side left -padx 4",
	"frame .f.g",
	"checkbutton .f.g.n -text NOT -variable gNOT",
	"checkbutton .f.g.a -text AND -variable gAND",
	"checkbutton .f.g.o -text OR -variable gOR",
	"checkbutton .f.g.d -text NAND -variable gNAND",
	"checkbutton .f.g.r -text NOR -variable gNOR",
	"checkbutton .f.g.x -text XOR -variable gXOR",
	"pack .f.g.n .f.g.a .f.g.o .f.g.d .f.g.r .f.g.x -side left -padx 2",
	"button .f.run -text Run synthesis -command {send cmd run}",
	"text .f.t -width 88 -height 18 -state disabled",
	"label .f.h -text {example A=F0 B=CC C=AA · Run · q quit}",
	"pack .f.gap .f.tl .f.in .f.out .f.g .f.run .f.t .f.h -side top -anchor w -pady 2",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Logic", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, ".f.in.a insert 0 F0");
	cmd(top, ".f.in.b insert 0 CC");
	cmd(top, ".f.in.c insert 0 AA");
	cmd(top, "variable gNOT 1");
	cmd(top, "variable gAND 1");
	cmd(top, "variable gOR 1");
	cmd(top, "variable gNAND 1");
	cmd(top, "variable gNOR 1");
	cmd(top, "variable gXOR 1");
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
	gate = array[TABLESIZE] of { * => GT_NULL };
	in1 = array[TABLESIZE] of int;
	in2 = array[TABLESIZE] of int;
	ninp = 0;
	nout = 0;
	outidx = -1;
	nsel = 0;

	if(cmd(top, "variable gNOT") == "1") selgates[nsel++] = GT_NOT;
	if(cmd(top, "variable gAND") == "1") selgates[nsel++] = GT_AND;
	if(cmd(top, "variable gOR") == "1") selgates[nsel++] = GT_OR;
	if(cmd(top, "variable gNAND") == "1") selgates[nsel++] = GT_NAND;
	if(cmd(top, "variable gNOR") == "1") selgates[nsel++] = GT_NOR;
	if(cmd(top, "variable gXOR") == "1") selgates[nsel++] = GT_XOR;
	if(nsel == 0){
		show("Select at least one gate.\n");
		return;
	}

	if(!markin(cmd(top, ".f.in.a get")) ||
	   !markin(cmd(top, ".f.in.b get")) ||
	   !markin(cmd(top, ".f.in.c get"))){
		show("Need three input hex indices (e.g. F0 CC AA).\n");
		return;
	}
	o1 := cmd(top, ".f.out.o1 get");
	o2 := cmd(top, ".f.out.o2 get");
	if(!markout(o1) && !markout(o2)){
		show("Enter at least one output hex index.\n");
		return;
	}
	markout(o2);

	found := synth();
	if(found <= 0){
		show(sys->sprint("Synthesis failed after %d passes (%d/%d outputs).\n",
			passes, found, nout));
		return;
	}
	tree := drawtree(outidx, 0, array[TABLESIZE] of int);
	show(sys->sprint("Found %d/%d outputs in %d passes.\n\n%s",
		found, nout, passes, tree));
}

markin(s: string): int
{
	if(s == "")
		return 0;
	v := parsehex(s);
	if(v < 0 || v >= TABLESIZE)
		return 0;
	if(gate[v] != GT_NULL)
		return 0;
	gate[v] = GT_INPUT;
	in1[v] = ninp++;
	return 1;
}

markout(s: string): int
{
	if(s == "")
		return 0;
	v := parsehex(s);
	if(v < 0 || v >= TABLESIZE)
		return 0;
	if(gate[v] == GT_INPUT){
		show(sys->sprint("Output %04X is input %c — connect directly.\n",
			v, 'A'+in1[v]));
		return 0;
	}
	if(gate[v] == GT_OUTPUT)
		return 1;
	gate[v] = GT_OUTPUT;
	in1[v] = nout++;
	nout++;
	return 1;
}

parsehex(s: string): int
{
	(_n, tok) := sys->tokenize(s, " \t");
	if(tok == nil)
		return -1;
	t := hd tok;
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

synth(): int
{
	added: array of int;
	found := 0;
	passes = 0;
	outidx = -1;
	mask := TABLESIZE - 1;

	for(pass := 0; pass < MAXPASS && found < nout; pass++){
		passes = pass + 1;
		added = array[TABLESIZE] of { * => 0 };
		chged := 0;
		ch: int;
		for(gi := 0; gi < nsel && found < nout; gi++){
			case selgates[gi] {
			GT_NOT =>
				(ch, found) = fillnot(added, mask, found);
				if(ch) chged = 1;
			GT_AND =>
				(ch, found) = filland(added, mask, found);
				if(ch) chged = 1;
			GT_OR =>
				(ch, found) = fillor(added, mask, found);
				if(ch) chged = 1;
			GT_NAND =>
				(ch, found) = fillnand(added, mask, found);
				if(ch) chged = 1;
			GT_NOR =>
				(ch, found) = fillnor(added, mask, found);
				if(ch) chged = 1;
			GT_XOR =>
				(ch, found) = fillxor(added, mask, found);
				if(ch) chged = 1;
			}
		}
		if(!chged)
			break;
	}
	return found;
}

usable(i: int, added: array of int): int
{
	return gate[i] > GT_OUTPUT && !added[i];
}

fillnot(added: array of int, mask, found: int): (int, int)
{
	ch := 0;
	for(i := 0; i < TABLESIZE; i++){
		if(!usable(i, added))
			continue;
		j := (~i) & mask;
		old := gate[j];
		if(old >= GT_INPUT)
			continue;
		gate[j] = GT_NOT;
		in1[j] = i;
		added[j] = 1;
		ch = 1;
		if(old == GT_OUTPUT){
			if(outidx < 0)
				outidx = j;
			found++;
		}
	}
	return (ch, found);
}

filland(added: array of int, mask, found: int): (int, int)
{
	ch := 0;
	for(i := 0; i < TABLESIZE; i++){
		if(!usable(i, added))
			continue;
		for(k := 0; k < TABLESIZE; k++){
			if(!usable(k, added))
				continue;
			j := (i & k) & mask;
			old := gate[j];
			if(old >= GT_INPUT)
				continue;
			gate[j] = GT_AND;
			in1[j] = i;
			in2[j] = k;
			added[j] = 1;
			ch = 1;
			if(old == GT_OUTPUT){
				if(outidx < 0)
					outidx = j;
				found++;
			}
		}
	}
	return (ch, found);
}

fillor(added: array of int, mask, found: int): (int, int)
{
	ch := 0;
	for(i := 0; i < TABLESIZE; i++){
		if(!usable(i, added))
			continue;
		for(k := 0; k < TABLESIZE; k++){
			if(!usable(k, added))
				continue;
			j := (i | k) & mask;
			old := gate[j];
			if(old >= GT_INPUT)
				continue;
			gate[j] = GT_OR;
			in1[j] = i;
			in2[j] = k;
			added[j] = 1;
			ch = 1;
			if(old == GT_OUTPUT){
				if(outidx < 0)
					outidx = j;
				found++;
			}
		}
	}
	return (ch, found);
}

fillnand(added: array of int, mask, found: int): (int, int)
{
	ch := 0;
	for(i := 0; i < TABLESIZE; i++){
		if(!usable(i, added))
			continue;
		for(k := 0; k < TABLESIZE; k++){
			if(!usable(k, added))
				continue;
			j := (~(i & k)) & mask;
			old := gate[j];
			if(old >= GT_INPUT)
				continue;
			gate[j] = GT_NAND;
			in1[j] = i;
			in2[j] = k;
			added[j] = 1;
			ch = 1;
			if(old == GT_OUTPUT){
				if(outidx < 0)
					outidx = j;
				found++;
			}
		}
	}
	return (ch, found);
}

fillnor(added: array of int, mask, found: int): (int, int)
{
	ch := 0;
	for(i := 0; i < TABLESIZE; i++){
		if(!usable(i, added))
			continue;
		for(k := 0; k < TABLESIZE; k++){
			if(!usable(k, added))
				continue;
			j := (~(i | k)) & mask;
			old := gate[j];
			if(old >= GT_INPUT)
				continue;
			gate[j] = GT_NOR;
			in1[j] = i;
			in2[j] = k;
			added[j] = 1;
			ch = 1;
			if(old == GT_OUTPUT){
				if(outidx < 0)
					outidx = j;
				found++;
			}
		}
	}
	return (ch, found);
}

fillxor(added: array of int, mask, found: int): (int, int)
{
	ch := 0;
	for(i := 0; i < TABLESIZE; i++){
		if(!usable(i, added))
			continue;
		for(k := 0; k < TABLESIZE; k++){
			if(!usable(k, added))
				continue;
			j := (i ^ k) & mask;
			old := gate[j];
			if(old >= GT_INPUT)
				continue;
			gate[j] = GT_XOR;
			in1[j] = i;
			in2[j] = k;
			added[j] = 1;
			ch = 1;
			if(old == GT_OUTPUT){
				if(outidx < 0)
					outidx = j;
				found++;
			}
		}
	}
	return (ch, found);
}

gname(t: int): string
{
	case t {
	GT_NOT => return "NOT";
	GT_AND => return "AND";
	GT_OR => return "OR";
	GT_NAND => return "NAND";
	GT_NOR => return "NOR";
	GT_XOR => return "XOR";
	GT_INPUT => return "IN";
	}
	return "?";
}

drawtree(idx, depth: int, seen: array of int): string
{
	if(idx < 0 || idx >= TABLESIZE)
		return "";
	if(seen[idx])
		return indent(depth)+"Dup %04X\n";
	seen[idx] = 1;
	ind := indent(depth);
	t := gate[idx];
	case t {
	GT_INPUT =>
		return ind+sys->sprint("IN %c [%04X]\n", 'A'+in1[idx], idx);
	GT_NOT =>
		return ind+sys->sprint("NOT [%04X]\n", idx)+drawtree(in1[idx], depth+1, seen);
	GT_AND =>
		return gate2(ind, idx, "AND", depth, seen);
	GT_OR =>
		return gate2(ind, idx, "OR", depth, seen);
	GT_NAND =>
		return gate2(ind, idx, "NAND", depth, seen);
	GT_NOR =>
		return gate2(ind, idx, "NOR", depth, seen);
	GT_XOR =>
		return gate2(ind, idx, "XOR", depth, seen);
	}
	return ind+sys->sprint("? [%04X]\n", idx);
}

gate2(ind: string, idx: int, name: string, depth: int, seen: array of int): string
{
	s := ind+sys->sprint("%s [%04X]\n", name, idx);
	s += drawtree(in1[idx], depth+1, seen);
	s += drawtree(in2[idx], depth+1, seen);
	return s;
}

indent(n: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s += "  ";
	return s;
}

show(msg: string)
{
	cmd(top, ".f.t configure -state normal");
	cmd(top, ".f.t delete 1.0 end");
	cmd(top, ".f.t insert end {"+msg+"}");
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
