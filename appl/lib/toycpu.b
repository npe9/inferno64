implement Toycpu;

# Nelson's Dream Machines chapter on Bucky's Wristwatch and "Rock
# Bottom" asks how few instructions something still recognisable as a
# *computer* actually needs - the pedagogical answer most CS courses
# converge on independently is some variant of the Little Man Computer:
# 100 numbered mailboxes (000-999 each), one accumulator, and about ten
# instructions. That's what this is - not a literal LMC clone (no
# claim any specific historical toy machine matches these exact
# mnemonics), but the same minimal spirit: an add, a subtract, a load,
# a store, an unconditional jump, two conditional jumps, input, output,
# halt. Everything else - loops, arrays via self-modifying jump targets,
# whatever - is built out of just that by whoever writes the program,
# same as the real thing.
#
# Assembly source, one mailbox per line:
#   [label] MNEMONIC [operand]
# MNEMONIC is one of INP OUT ADD SUB STA/STO LDA BRA BRZ BRP DAT HLT/COB.
# operand is a mailbox address, a label defined elsewhere in the same
# program, or (DAT only, ordinarily) a literal value to preload that
# mailbox with. Blank lines and "# comment" trailers are ignored. If
# the first token on a line isn't a recognised mnemonic, it's taken as
# a label naming the mailbox at that line's position (a user labelling
# a mailbox the same as a mnemonic loses that ambiguity to "it's a
# mnemonic" - a real, if unlikely, corner this parser doesn't chase).
#
# Instruction word = opcode*100 + address, matching the mailboxes'
# own three-digit width:
#   000        HLT/COB (halt)
#   1xx ADD    acc += mem[xx]
#   2xx SUB    acc -= mem[xx] (sets negflag if this went below zero)
#   3xx STA/STO mem[xx] = acc
#   5xx LDA    acc = mem[xx]
#   6xx BRA    pc = xx
#   7xx BRZ    pc = xx if acc == 0
#   8xx BRP    pc = xx if negflag is clear (acc has stayed non-negative)
#   901 INP    acc = next queued input (see step()'s "input" status)
#   902 OUT    queues acc onto the machine's output
# 4xx and other 9xx codes aren't assigned to anything - executing one
# halts with an error, the same as running off the end of a real
# machine's instruction set.

include "sys.m";
	sys: Sys;
include "toycpu.m";

init()
{
	sys = load Sys Sys->PATH;
}

Line: adt {
	label:	string;
	mnem:	string;
	operand: string;
};

Lbl: adt {
	name:	string;
	addr:	int;
};

mnemonics := array[] of {"HLT", "COB", "INP", "OUT", "ADD", "SUB", "STA", "STO", "LDA", "BRA", "BRZ", "BRP", "DAT"};

assemble(src: string): (array of int, string)
{
	(nil, srclines) := sys->tokenize(src, "\n");
	lines: list of ref Line;
	nlines := 0;
	for(sl := srclines; sl != nil; sl = tl sl){
		line := stripcomment(hd sl);
		(n, toks) := sys->tokenize(line, " \t");
		if(n == 0)
			continue;
		t0 := upper(hd toks);
		label := "";
		mnem: string;
		rest: list of string;
		if(ismnemonic(t0)){
			mnem = t0;
			rest = tl toks;
		}else{
			label = hd toks;
			if(tl toks == nil)
				return (nil, sys->sprint("line %q: missing mnemonic after label", line));
			mnem = upper(hd tl toks);
			if(!ismnemonic(mnem))
				return (nil, sys->sprint("line %q: unknown mnemonic %q", line, mnem));
			rest = tl tl toks;
		}
		operand := "";
		if(rest != nil)
			operand = hd rest;
		lines = ref Line(label, mnem, operand) :: lines;
		nlines++;
		if(nlines > Mem)
			return (nil, sys->sprint("program too large (max %d mailboxes)", Mem));
	}
	lines = revlines(lines);

	labels: list of ref Lbl;
	addr := 0;
	for(l := lines; l != nil; l = tl l){
		if((hd l).label != "")
			labels = ref Lbl((hd l).label, addr) :: labels;
		addr++;
	}

	mem := array[Mem] of {* => 0};
	addr = 0;
	for(l = lines; l != nil; l = tl l){
		ln := hd l;
		(word, err) := encode(ln.mnem, ln.operand, labels);
		if(err != nil)
			return (nil, sys->sprint("line %d (%s): %s", addr, ln.mnem, err));
		mem[addr] = word;
		addr++;
	}
	return (mem, nil);
}

encode(mnem: string, operand: string, labels: list of ref Lbl): (int, string)
{
	case mnem {
	"HLT" or "COB" =>
		return (0, nil);
	"INP" =>
		return (901, nil);
	"OUT" =>
		return (902, nil);
	"DAT" =>
		if(operand == "")
			return (0, nil);
		return resolve(operand, labels);
	"ADD" =>
		(a, err) := resolve(operand, labels);
		return (100+a, err);
	"SUB" =>
		(a, err) := resolve(operand, labels);
		return (200+a, err);
	"STA" or "STO" =>
		(a, err) := resolve(operand, labels);
		return (300+a, err);
	"LDA" =>
		(a, err) := resolve(operand, labels);
		return (500+a, err);
	"BRA" =>
		(a, err) := resolve(operand, labels);
		return (600+a, err);
	"BRZ" =>
		(a, err) := resolve(operand, labels);
		return (700+a, err);
	"BRP" =>
		(a, err) := resolve(operand, labels);
		return (800+a, err);
	}
	return (0, "unknown mnemonic " + mnem);
}

resolve(operand: string, labels: list of ref Lbl): (int, string)
{
	if(operand == "")
		return (0, "missing operand");
	if(isnumeric(operand))
		return (toint(operand), nil);
	for(l := labels; l != nil; l = tl l)
		if((hd l).name == operand)
			return ((hd l).addr, nil);
	return (0, "undefined label " + operand);
}

newmachine(mem: array of int): ref Machine
{
	m := ref Machine(array[Mem] of int, 0, 0, 0, 0, nil, nil);
	for(i := 0; i < Mem; i++){
		if(mem != nil && i < len mem)
			m.mem[i] = mem[i];
		else
			m.mem[i] = 0;
	}
	return m;
}

# Executes one instruction. Returns "" on an ordinary step, "halt" once
# HLT has run (or on any further call - a halted machine just stays
# halted), "input" if the instruction at pc is INP and no input has
# been queued yet (pc does *not* advance - call input() then step()
# again to actually complete it), or an "error: ..." string for an
# unassigned opcode (which also halts, same as a real machine jamming).
step(m: ref Machine): string
{
	if(m.halted)
		return "halt";
	instr := m.mem[m.pc];
	op := instr/100;
	addr := instr%100;
	case op {
	0 =>
		m.halted = 1;
		return "halt";
	1 =>
		m.acc = (m.acc + m.mem[addr]) % 1000;
		m.negflag = 0;
		m.pc = (m.pc+1)%Mem;
	2 =>
		v := m.acc - m.mem[addr];
		if(v < 0){
			m.negflag = 1;
			v += 1000;
		}else
			m.negflag = 0;
		m.acc = v%1000;
		m.pc = (m.pc+1)%Mem;
	3 =>
		m.mem[addr] = m.acc;
		m.pc = (m.pc+1)%Mem;
	5 =>
		m.acc = m.mem[addr];
		m.negflag = 0;
		m.pc = (m.pc+1)%Mem;
	6 =>
		m.pc = addr;
	7 =>
		if(m.acc == 0)
			m.pc = addr;
		else
			m.pc = (m.pc+1)%Mem;
	8 =>
		if(!m.negflag)
			m.pc = addr;
		else
			m.pc = (m.pc+1)%Mem;
	9 =>
		if(instr == 901){
			if(m.inq == nil)
				return "input";
			m.acc = hd m.inq;
			m.inq = tl m.inq;
			m.negflag = 0;
			m.pc = (m.pc+1)%Mem;
		}else if(instr == 902){
			m.outq = appendint(m.outq, m.acc);
			m.pc = (m.pc+1)%Mem;
		}else{
			m.halted = 1;
			return sys->sprint("error: bad instruction %03d", instr);
		}
	* =>
		m.halted = 1;
		return sys->sprint("error: bad instruction %03d", instr);
	}
	return "";
}

input(m: ref Machine, v: int)
{
	m.inq = appendint(m.inq, v);
}

ismnemonic(s: string): int
{
	for(i := 0; i < len mnemonics; i++)
		if(mnemonics[i] == s)
			return 1;
	return 0;
}

isnumeric(s: string): int
{
	if(len s == 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

toint(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++)
		v = v*10 + (s[i]-'0');
	return v;
}

upper(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'a' && r[i] <= 'z')
			r[i] = r[i]-'a'+'A';
	return r;
}

stripcomment(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '#')
			return s[0:i];
	return s;
}

appendint(l: list of int, v: int): list of int
{
	if(l == nil)
		return v :: nil;
	return hd l :: appendint(tl l, v);
}

revlines(l: list of ref Line): list of ref Line
{
	r: list of ref Line;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
