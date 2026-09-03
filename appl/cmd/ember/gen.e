module Gen

import sys "sys"
import types "types"

const INOP = 0
const IALT = 1
const INBALT = 2
const IGOTO = 3
const ICALL = 4
const IFRAME = 5
const ISPAWN = 6
const IRUNT = 7
const ILOAD = 8
const IMCALL = 9
const IMSPAWN = 10
const IMFRAME = 11
const IRET = 12
const IJMP = 13
const ICASE = 14
const IEXIT = 15
const INEW = 16
const INEWA = 17
const INEWCB = 18
const INEWCW = 19
const INEWCF = 20
const INEWCP = 21
const INEWCM = 22
const INEWCMP = 23
const ISEND = 24
const IRECV = 25
const ICONSB = 26
const ICONSW = 27
const ICONSP = 28
const ICONSF = 29
const ICONSM = 30
const ICONSMP = 31
const IHEADB = 32
const IHEADW = 33
const IHEADP = 34
const IHEADF = 35
const IHEADM = 36
const IHEADMP = 37
const ITAIL = 38
const ILEA = 39
const IINDX = 40
const IMOVP = 41
const IMOVM = 42
const IMOVMP = 43
const IMOVB = 44
const IMOVW = 45
const IMOVF = 46
const ICVTBW = 47
const ICVTWB = 48
const ICVTFW = 49
const ICVTWF = 50
const ICVTCA = 51
const ICVTAC = 52
const ICVTWC = 53
const ICVTCW = 54
const ICVTFC = 55
const ICVTCF = 56
const IADDB = 57
const IADDW = 58
const IADDF = 59
const ISUBB = 60
const ISUBW = 61
const ISUBF = 62
const IMULB = 63
const IMULW = 64
const IMULF = 65
const IDIVB = 66
const IDIVW = 67
const IDIVF = 68
const IMODW = 69
const IMODB = 70
const IANDB = 71
const IANDW = 72
const IORB = 73
const IORW = 74
const IXORB = 75
const IXORW = 76
const ISHLB = 77
const ISHLW = 78
const ISHRB = 79
const ISHRW = 80
const IINSC = 81
const IINDC = 82
const IADDC = 83
const ILENC = 84
const ILENA = 85
const ILENL = 86
const IBEQB = 87
const IBNEB = 88
const IBLTB = 89
const IBLEB = 90
const IBGTB = 91
const IBGEB = 92
const IBEQW = 93
const IBNEW = 94
const IBLTW = 95
const IBLEW = 96
const IBGTW = 97
const IBGEW = 98
const IBEQF = 99
const IBNEF = 100
const IBLTF = 101
const IBLEF = 102
const IBGTF = 103
const IBGEF = 104
const IBEQC = 105
const IBNEC = 106
const IBLTC = 107
const IBLEC = 108
const IBGTC = 109
const IBGEC = 110
const ISLICEA = 111
const ISLICELA = 112
const ISLICEC = 113
const IINDW = 114
const IINDF = 115
const IINDB = 116
const INEGF = 117
const IMOVL = 118
const IADDL = 119
const ISUBL = 120
const IDIVL = 121
const IMODL = 122
const IMULL = 123
const IANDL = 124
const IORL = 125
const IXORL = 126
const ISHLL = 127
const ISHRL = 128
const IBNEL = 129
const IBLTL = 130
const IBLEL = 131
const IBGTL = 132
const IBGEL = 133
const IBEQL = 134
const ICVTLF = 135
const ICVTFL = 136
const ICVTLW = 137
const ICVTWL = 138
const ICVTLC = 139
const ICVTCL = 140
const IHEADL = 141
const ICONSL = 142
const INEWCL = 143
const ICASEC = 144
const IINDL = 145
const IMOVPC = 146
const ITCMP = 147
const IMNEWZ = 148
const ICVTRF = 149
const ICVTFR = 150
const ICVTWS = 151
const ICVTSW = 152
const ILSRW = 153
const ILSRL = 154
const IECLR = 155
const INEWZ = 156
const INEWAZ = 157
const IRAISE = 158
const ICASEL = 159
const IMULX = 160
const IDIVX = 161
const ICVTXX = 162
const IMULX0 = 163
const IDIVX0 = 164
const ICVTXX0 = 165
const IMULX1 = 166
const IDIVX1 = 167
const ICVTXX1 = 168
const ICVTFX = 169
const ICVTXF = 170
const IEXPW = 171
const IEXPL = 172
const IEXPF = 173
const ISELF = 174
const MAXDIS = 175
const IEXC = 175
const IEXC0 = 176
const INOOP = 177

const Rreg = 0
const Rmreg = 1
const Roff = 2
const Rnoff = 3
const Rdesc = 4
const Rdescp = 5
const Rconst = 6
const Ralways = 7
const Radr = 8
const Rmadr = 9
const Rcant = 10
const Rpc = 11
const Rmpc = 12
const Rareg = 13
const Ramreg = 14
const Raadr = 15
const Ramadr = 16
const Rldt = 17
const Rend = 18

const Aimm = 0
const Amp = 1
const Ampind = 2
const Afp = 3
const Afpind = 4
const Apc = 5
const Adesc = 6
const Aoff = 7
const Anoff = 8
const Aerr = 9
const Anone = 10
const Aldt = 11
const Aend = 12

const Mas = 0
const Mcons = 1
const Mhd = 2
const Mtl = 3
const Mend = 4

const NREG = 5
const REGRET = 4
const STemp = 40
const RTemp = 48
const DTemp = 56
const MaxReg = 65536

func usetypes(t Types) {
	types = t
}

func fatal(msg string) {
	sys.fprint(sys.fildes(2), "fatal ember compiler error: %s\n", msg)
	raisefatal()
}

func raisefatal() {
	var l list int
	hd(l)	// a deliberate nil-list fault stops the compiler
}

// addressing mode per addressability class (gen.c's addrmode[])
var addrmodes = [Rend]int{Afp, Amp, Aoff, Anoff, Adesc, Adesc, Aimm, Aerr, Afpind, Ampind, Aerr, Apc, Aerr, Aerr, Aerr, Aerr, Aerr, Aldt}

func addrmode(r int) int {
	return addrmodes[r]
}

var wtemp ref types.Decl
var bigtemp ref types.Decl
var ntemp = 0
var retnode ref types.Node
var first ref types.Inst
var last ref types.Inst
var curblocks = -1
var blockstack []int
var blockdep = 0
var nblocks = 0
var curmaxstack = 0

func firstinst() ref types.Inst {
	return first
}

func lastinst() ref types.Inst {
	return last
}

func setlastinst(in ref types.Inst) {
	last = in
}

func setfirstinst(in ref types.Inst) {
	first = in
}

func blocks() int {
	return curblocks
}

func maxstack() int {
	return curmaxstack
}

func setmaxstack(n int) {
	curmaxstack = n
}

func zinst() ref types.Inst {
	return ref types.Inst{op: INOP, sm: Anone, dm: Anone, mm: Anone}
}

func genstart() {
	d := types.mkdecl(0, 0, types.Dlocal, types.basic(types.Tint))
	d.sym = ".ret"
	d.offset = types.IBY2WD * REGRET
	retnode = ref types.Node{op: types.Oname, addable: Rreg, decl: d, ty: types.basic(types.Tint)}
	first = zinst()
	last = first
	curblocks = -1
	blockdep = 0
	nblocks = 0
	ntemp = 0
}

func retalloc(n ref types.Node, nn ref types.Node) ref types.Node {
	if nn.ty == types.basic(types.Tnone) {
		return nil
	}
	n.op = types.Oind
	n.addable = Radr
	n.left = ref types.Node{op: retnode.op, addable: retnode.addable, decl: retnode.decl, ty: retnode.ty, line: n.line, pos: n.pos}
	n.ty = nn.ty
	return n
}

// split the globals into ordinary ones and interface tables
func resolveldts(d ref types.Decl) (ref types.Decl, ref types.Decl) {
	var d1 ref types.Decl
	var ld1 ref types.Decl
	var d2 ref types.Decl
	var ld2 ref types.Decl
	for d != nil {
		n := d.next
		d.next = nil
		if d.ty != nil && d.ty.kind == types.Tiface {
			if d2 == nil {
				d2 = d
			} else {
				ld2.next = d
			}
			ld2 = d
		} else {
			if d1 == nil {
				d1 = d
			} else {
				ld1.next = d
			}
			ld1 = d
		}
		d = n
	}
	return d1, d2
}

func pushblock() int {
	if blockstack == nil || blockdep >= len(blockstack) {
		nb := [blockdep + 32]int
		for i := 0; i < blockdep; i++ {
			nb[i] = blockstack[i]
		}
		blockstack = nb
	}
	blockstack[blockdep] = curblocks
	blockdep++
	curblocks = nblocks
	nblocks++
	return curblocks
}

func popblock() {
	blockdep--
	curblocks = blockstack[blockdep]
}

func tinit() {
	wtemp = nil
	bigtemp = nil
}

func tdecls() ref types.Decl {
	for d := wtemp; d != nil; d = d.next {
		if d.tref != 1 {
			fatal(sys.sprint("temporary %s has %d references", d.sym, d.tref - 1))
		}
	}
	for d := bigtemp; d != nil; d = d.next {
		if d.tref != 1 {
			fatal(sys.sprint("temporary %s has %d references", d.sym, d.tref - 1))
		}
	}
	return types.appdecls(wtemp, bigtemp)
}

func talloc(n ref types.Node, t ref types.Type, nok ref types.Node) ref types.Node {
	if t.size == 0 && t.kind != types.Tfn && t.kind != types.Tainit {
		fatal(sys.sprint("talloc: unsized type %s (kind %d) -- missing sizetype()?", types.tprint(t), t.kind))
	}
	var ok ref types.Decl
	if nok != nil {
		ok = nok.decl
	}
	if ok == nil || ok.tref == 0 || types.isbig(ok.ty.kind) != types.isbig(t.kind) || ok.ty.align != t.align {
		ok = nil
	}
	n.op = types.Oname
	n.addable = Rreg
	n.ty = t
	if types.isbig(t.kind) != 0 {
		desc := types.mktdesc(t)
		if ok != nil && ok.desc == desc {
			ok.tref++
			ok.refs++
			n.decl = ok
			return n
		}
		for d := bigtemp; d != nil; d = d.next {
			if d.tref == 1 && d.desc == desc && d.ty.align == t.align {
				d.tref++
				d.refs++
				n.decl = d
				return n
			}
		}
		d := types.mkdecl(0, 0, types.Dlocal, t)
		d.desc = desc
		d.tref = 2
		d.refs = 1
		n.decl = d
		d.sym = sys.sprint(".b%d", ntemp)
		ntemp++
		d.next = bigtemp
		bigtemp = d
		return n
	}
	if ok != nil && types.isptr(ok.ty.kind) == types.isptr(t.kind) && ok.ty.size == t.size {
		ok.tref++
		n.decl = ok
		return n
	}
	for d := wtemp; d != nil; d = d.next {
		if d.tref == 1 && types.isptr(d.ty.kind) == types.isptr(t.kind) && d.ty.size == t.size && d.ty.align == t.align {
			d.tref++
			n.decl = d
			return n
		}
	}
	d := types.mkdecl(0, 0, types.Dlocal, t)
	d.tref = 2
	d.refs = 1
	n.decl = d
	d.sym = sys.sprint(".t%d", ntemp)
	ntemp++
	d.next = wtemp
	wtemp = d
	return n
}

func mktn(t ref types.Type) ref types.Node {
	n := types.mkn(types.Oname, nil, nil)
	types.usedesc(types.mktdesc(t))
	n.ty = t
	n.decl = t.decl
	if n.decl == nil {
		fatal(sys.sprint("mktn t %s nil decl", types.tprint(t)))
	}
	n.addable = Rdesc
	return n
}

func tfree(n ref types.Node) {
	if n == nil || n.decl == nil || n.decl.tref == 0 {
		return
	}
	if n.decl.tref == 1 {
		fatal(sys.sprint("double free of temporary %s", n.decl.sym))
	}
	n.decl.tref--
}

func mkinst() ref types.Inst {
	in := last.next
	if in == nil {
		in = zinst()
		last.next = in
	}
	last = in
	in.block = curblocks
	if curblocks < 0 {
		fatal("mkinst no block")
	}
	return in
}

func nextinst() ref types.Inst {
	in := last.next
	if in != nil {
		return in
	}
	in = zinst()
	last.next = in
	return in
}

func setops(in ref types.Inst, s ref types.Node, m ref types.Node, d ref types.Node) {
	if s != nil {
		in.s = genaddr(s)
		in.sm = addrmodes[s.addable]
	}
	if m != nil {
		in.m = genaddr(m)
		in.mm = addrmodes[m.addable]
		if in.mm == Ampind || in.mm == Afpind {
			fatal("illegal addressing mode in register")
		}
	}
	if d != nil {
		in.d = genaddr(d)
		in.dm = addrmodes[d.addable]
	}
}

func genrawop(line int, pos int, op int, s ref types.Node, m ref types.Node, d ref types.Node) ref types.Inst {
	in := mkinst()
	in.op = op
	in.line = line
	in.pos = pos
	if in.sm != Anone || in.mm != Anone || in.dm != Anone {
		fatal("bogus mkinst in genrawop")
	}
	setops(in, s, m, d)
	return in
}

// column of the instruction tables for a type kind
func opind(kind int) int {
	match kind {
	case types.Tbyte:
		return 1
	case types.Tint:
		return 2
	case types.Tbig:
		return 3
	case types.Treal:
		return 4
	case types.Tstring:
		return 5
	case types.Tfix:
		return 6
	}
	return 0
}

// optab.c's disoptab: the Dis instruction for an ember op on a kind
func disop(op int, kind int) int {
	c := opind(kind)
	match op {
	case types.Oadd, types.Oaddas:
		return [7]int{0, IADDB, IADDW, IADDL, IADDF, IADDC, IADDW}[c]
	case types.Oand, types.Oandas:
		return [7]int{0, IANDB, IANDW, IANDL, 0, 0, 0}[c]
	case types.Odec:
		return [7]int{0, ISUBB, ISUBW, ISUBL, ISUBF, 0, ISUBW}[c]
	case types.Odiv, types.Odivas:
		return [7]int{0, IDIVB, IDIVW, IDIVL, IDIVF, 0, IDIVX}[c]
	case types.Oeq:
		return [7]int{IBEQW, IBEQB, IBEQW, IBEQL, IBEQF, IBEQC, IBEQW}[c]
	case types.Ogeq:
		return [7]int{0, IBGEB, IBGEW, IBGEL, IBGEF, IBGEC, IBGEW}[c]
	case types.Ogt:
		return [7]int{0, IBGTB, IBGTW, IBGTL, IBGTF, IBGTC, IBGTW}[c]
	case types.Oinc:
		return [7]int{0, IADDB, IADDW, IADDL, IADDF, 0, IADDW}[c]
	case types.Oinds:
		return [7]int{0, 0, IINDC, 0, 0, 0, 0}[c]
	case types.Oindx:
		return [7]int{0, 0, IINDX, 0, 0, 0, 0}[c]
	case types.Olen:
		return [7]int{ILENA, 0, 0, 0, 0, ILENC, 0}[c]
	case types.Oleq:
		return [7]int{0, IBLEB, IBLEW, IBLEL, IBLEF, IBLEC, IBLEW}[c]
	case types.Olsh, types.Olshas:
		return [7]int{0, ISHLB, ISHLW, ISHLL, 0, 0, 0}[c]
	case types.Olt:
		return [7]int{0, IBLTB, IBLTW, IBLTL, IBLTF, IBLTC, IBLTW}[c]
	case types.Omod, types.Omodas:
		return [7]int{0, IMODB, IMODW, IMODL, 0, 0, 0}[c]
	case types.Omul, types.Omulas:
		return [7]int{0, IMULB, IMULW, IMULL, IMULF, 0, IMULX}[c]
	case types.Oneg:
		return [7]int{0, 0, 0, 0, INEGF, 0, 0}[c]
	case types.Oneq:
		return [7]int{IBNEW, IBNEB, IBNEW, IBNEL, IBNEF, IBNEC, IBNEW}[c]
	case types.Oor, types.Ooras:
		return [7]int{0, IORB, IORW, IORL, 0, 0, 0}[c]
	case types.Orsh, types.Orshas:
		return [7]int{0, ISHRB, ISHRW, ISHRL, 0, 0, 0}[c]
	case types.Oslice:
		return [7]int{ISLICEA, 0, 0, 0, 0, ISLICEC, 0}[c]
	case types.Osub, types.Osubas:
		return [7]int{0, ISUBB, ISUBW, ISUBL, ISUBF, 0, ISUBW}[c]
	case types.Oxor, types.Oxoras:
		return [7]int{0, IXORB, IXORW, IXORL, 0, 0, 0}[c]
	}
	return 0
}

func isbyteinst(op int) int {
	match op {
	case IMULB, ISUBB, IADDB, IDIVB, IORB, IXORB, ISHLB, ISHRB, IMODB, IANDB, IBEQB, IBNEB, IBLTB, IBLEB, IBGTB, IBGEB:
		return 1
	}
	return 0
}

func genop(line int, pos int, op int, s ref types.Node, m ref types.Node, d ref types.Node) ref types.Inst {
	iop := disop(op, d.ty.kind)
	if iop == 0 {
		fatal(sys.sprint("can't deal with op %s on %s in genop", types.opname(op), types.tprint(d.ty)))
	}
	in := mkinst()
	in.op = iop
	in.line = line
	in.pos = pos
	setops(in, s, m, d)
	return in
}

func genbra(line int, pos int, op int, s ref types.Node, m ref types.Node) ref types.Inst {
	t := s.ty
	if t == types.basic(types.Tany) {
		t = m.ty
	}
	iop := disop(op, t.kind)
	if iop == 0 {
		fatal(sys.sprint("can't deal with op %s on %s in genbra", types.opname(op), types.tprint(t)))
	}
	in := mkinst()
	in.op = iop
	in.line = line
	in.pos = pos
	setops(in, s, m, nil)
	return in
}

// optab.c's chantab and movetab
func chanop(kind int) int {
	return [types.Tend]int{0, INEWCM, 0, INEWCP, INEWCL, INEWCB, INEWCP, INEWCF, 0, INEWCW, INEWCP, INEWCP, INEWCP, INEWCP, INEWCM, INEWCM, INEWCW, INEWCP, 0, 0, INEWCP, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}[kind]
}

func moveop(how int, kind int) int {
	match how {
	case Mas:
		return [types.Tend]int{0, IMOVM, IMOVM, IMOVP, IMOVL, IMOVB, IMOVP, IMOVF, 0, IMOVW, IMOVP, IMOVP, IMOVP, IMOVP, IMOVM, IMOVM, IMOVW, IMOVP, 0, 0, IMOVP, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}[kind]
	case Mcons:
		return [types.Tend]int{0, ICONSM, 0, ICONSP, ICONSL, ICONSB, ICONSP, ICONSF, 0, ICONSW, ICONSP, ICONSP, ICONSP, ICONSP, ICONSM, ICONSM, ICONSW, ICONSP, 0, 0, ICONSP, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}[kind]
	case Mhd:
		return [types.Tend]int{0, IHEADM, 0, IHEADP, IHEADL, IHEADB, IHEADP, IHEADF, 0, IHEADW, IHEADP, IHEADP, IHEADP, IHEADP, IHEADM, IHEADM, IHEADW, IHEADP, 0, 0, IHEADP, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}[kind]
	case Mtl:
		if kind == types.Tlist {
			return ITAIL
		}
		return 0
	}
	return 0
}

func genchan(line int, pos int, sz ref types.Node, mt ref types.Type, d ref types.Node) ref types.Inst {
	regm := Anone
	reg := types.Addr{reg: 0, offset: 0, decl: nil}
	op := chanop(mt.kind)
	if op == 0 {
		fatal(sys.sprint("can't deal with type %s in genchan", types.tprint(mt)))
	}
	match mt.kind {
	case types.Tadt, types.Tadtpick, types.Ttuple:
		td := types.mktdesc(mt)
		if td.nmap != 0 {
			op++
			types.usedesc(td)
			regm = Adesc
			reg.decl = mt.decl
		} else {
			regm = Aimm
			reg.offset = mt.size
		}
	}
	in := mkinst()
	in.op = op
	in.line = line
	in.pos = pos
	in.s = reg
	in.sm = regm
	if sz != nil {
		in.m = genaddr(sz)
		in.mm = addrmodes[sz.addable]
	}
	if d != nil {
		in.d = genaddr(d)
		in.dm = addrmodes[d.addable]
	}
	return in
}

func genmove(line int, pos int, how int, mt ref types.Type, s ref types.Node, d ref types.Node) ref types.Inst {
	regm := Anone
	reg := types.Addr{reg: 0, offset: 0, decl: nil}
	op := moveop(how, mt.kind)
	if op == 0 {
		fatal(sys.sprint("can't deal with how %d type %s in genmove", how, types.tprint(mt)))
	}
	match mt.kind {
	case types.Tadt, types.Tadtpick, types.Ttuple, types.Texception:
		if mt.size == 0 && how == Mas {
			return nil
		}
		td := types.mktdesc(mt)
		if td.nmap != 0 {
			op++
			types.usedesc(td)
			regm = Adesc
			reg.decl = mt.decl
		} else {
			regm = Aimm
			reg.offset = mt.size
		}
	}
	in := mkinst()
	in.op = op
	in.line = line
	in.pos = pos
	if s != nil {
		in.s = genaddr(s)
		in.sm = addrmodes[s.addable]
	}
	in.m = reg
	in.mm = regm
	if d != nil {
		in.d = genaddr(d)
		in.dm = addrmodes[d.addable]
	}
	if s.addable == Rpc {
		in.op = IMOVPC
	}
	return in
}

func patch(b ref types.Inst, dst ref types.Inst) {
	for b != nil {
		n := b.branch
		b.branch = dst
		b = n
	}
}

func getpc(i ref types.Inst) int {
	if i.pc == 0 && i != first && (first.op != INOOP || i != first.next) {
		i = i.next
		for i != nil && i.pc == 0 {
			i = i.next
		}
		if i == nil || i.pc == 0 {
			fatal("bad instruction in getpc")
			return 0
		}
	}
	return i.pc
}

func reach(in ref types.Inst) {
	foldbranch(in)
	lastr := in
	for in = in.next; in != nil; in = in.next {
		if in.reach == 0 {
			lastr.next = in.next
		} else {
			lastr = in
		}
	}
	last = lastr
}

// copy an instruction's contents (gen.c's *in = *b)
func copyinst(dst ref types.Inst, src ref types.Inst) {
	dst.line = src.line
	dst.pos = src.pos
	dst.op = src.op
	dst.pc = src.pc
	dst.reach = src.reach
	dst.sm = src.sm
	dst.mm = src.mm
	dst.dm = src.dm
	dst.s = src.s
	dst.m = src.m
	dst.d = src.d
	dst.branch = src.branch
	dst.next = src.next
	dst.block = src.block
}

func foldbranch(in ref types.Inst) {
	for in != nil && in.reach == 0 {
		in.reach = 1
		if in.branch != nil {
			for in.branch.op == IJMP {
				if in == in.branch || in.branch == in.branch.branch {
					break
				}
				in.branch = in.branch.branch
			}
		}
		match in.op {
		case IGOTO, ICASE, ICASEL, ICASEC, IEXC:
			foldbranch(in.d.decl.ty.cse.iwild)
			lab := in.d.decl.ty.cse.labs
			n := in.d.decl.ty.cse.nlab
			for i := 0; i < n; i++ {
				foldbranch(lab[i].inst)
			}
			if in.op == IEXC {
				in.op = INOOP
			}
			return
		case IEXC0:
			foldbranch(in.branch)
			in.op = INOOP
		case IRET, IEXIT, IRAISE:
			return
		case IJMP:
			b := in.branch
			if b == nil {
				fatal("foldbranch: jump without a target")
			}
			match b.op {
			case ICASE, ICASEL, ICASEC, IRET, IEXIT:
				next := in.next
				copyinst(in, b)
				in.next = next
				continue
			}
			foldbranch(b)
			return
		default:
			if in.branch != nil {
				foldbranch(in.branch)
			}
		}
		in = in.next
	}
}

func genaddr(n ref types.Node) types.Addr {
	a := types.Addr{reg: 0, offset: 0, decl: nil}
	if n == nil {
		return a
	}
	match n.addable {
	case Rreg, Rmreg:
		if n.decl != nil {
			a.decl = n.decl
		} else {
			a = genaddr(n.left)
		}
	case Rdesc:
		a.decl = n.ty.decl
	case Roff, Rnoff:
		a.decl = n.decl
	case Rconst:
		a.offset = int(n.val)
	case Radr, Rmadr:
		a = genaddr(n.left)
	case Rareg, Ramreg:
		a = genaddr(n.left)
		if n.op == types.Oadd {
			a.reg += int(n.right.val)
		}
	case Raadr, Ramadr:
		a = genaddr(n.left)
		if n.op == types.Oadd {
			a.offset += int(n.right.val)
		}
	case Rldt, Rdescp, Rpc:
		a.decl = n.decl
	default:
		fatal(sys.sprint("can't deal with addressable %d in genaddr", n.addable))
	}
	return a
}

func resolvedesc(mod ref types.Decl, length int, decls ref types.Decl) int {
	g := types.gendesc(mod, length, decls)
	g.used = 0
	var lastd ref types.Desc
	descs := types.descriptorlist()
	for d := descs; d != nil; d = d.next {
		if d.used == 0 {
			if lastd != nil {
				lastd.next = d.next
			} else {
				descs = d.next
			}
			continue
		}
		lastd = d
	}
	g.next = descs
	types.setdescriptorlist(g)
	descid := 0
	for d := g; d != nil; d = d.next {
		d.id = descid
		descid++
	}
	if g.id != 0 {
		fatal("bad global descriptor id")
	}
	return descid
}

func resolvepcs(inst ref types.Inst) int {
	pc := 0
	for in := inst; in != nil; in = in.next {
		if in.reach == 0 || in.op == INOP {
			fatal(sys.sprint("unreachable pc: %d", pc))
		}
		if in.op == INOOP {
			in.pc = pc
			continue
		}
		d := in.s.decl
		if d != nil {
			if in.sm == Adesc {
				if d.desc != nil {
					in.s.offset = d.desc.id
				}
			} else {
				in.s.reg += d.offset
			}
		}
		if (in.sm == Afpind || in.sm == Ampind) && (in.s.reg >= MaxReg || in.s.offset >= MaxReg) {
			fatal("big offset")
		}
		d = in.m.decl
		if d != nil {
			if in.mm == Adesc {
				if d.desc != nil {
					in.m.offset = d.desc.id
				}
			} else {
				in.m.reg += d.offset
			}
		}
		v := 0
		match in.mm {
		case Anone:
			v = 0
		case Aimm, Apc, Adesc:
			v = in.m.offset
		case Aoff, Anoff:
			v = in.m.decl.iface.offset
		case Afp, Amp, Aldt:
			v = in.m.reg
			if v < 0 {
				v = 32768
			}
		default:
			fatal("can't deal with m mode")
		}
		if v > 32767 || v < -32768 {
			match in.op {
			case IALT, IINDX:
				rewritedestreg(in, IMOVW, RTemp)
			default:
				op := IMOVW
				if isbyteinst(in.op) != 0 {
					op = IMOVB
				}
				in = rewritesrcreg(in, op, RTemp, pc)
				pc++
			}
		}
		d = in.d.decl
		if d != nil {
			if in.dm == Apc {
				if d.pc == nil {
					fatal(sys.sprint("resolvepcs: %s has no pc (op %d)", d.sym, in.op))
				}
				in.d.offset = d.pc.pc
			} else {
				in.d.reg += d.offset
			}
		}
		if (in.dm == Afpind || in.dm == Ampind) && (in.d.reg >= MaxReg || in.d.offset >= MaxReg) {
			fatal("big offset")
		}
		in.pc = pc
		pc++
	}
	for in := inst; in != nil; in = in.next {
		d := in.s.decl
		if d != nil && in.sm == Apc {
			if d.pc == nil {
				fatal(sys.sprint("resolvepcs: source %s has no pc", d.sym))
			}
			in.s.offset = d.pc.pc
		}
		d = in.d.decl
		if d != nil && in.dm == Apc {
			if d.pc == nil {
				fatal(sys.sprint("resolvepcs: %s has no pc", d.sym))
			}
			in.d.offset = d.pc.pc
		}
		if in.branch != nil {
			in.dm = Apc
			in.d.offset = in.branch.pc
		}
	}
	return pc
}

// an over-wide middle operand: load it into a scratch register first
func rewritesrcreg(in ref types.Inst, op int, treg int, pc int) ref types.Inst {
	a := in.m
	am := in.mm
	in.mm = Afp
	in.m.reg = treg
	in.m.decl = nil
	new := zinst()
	copyinst(new, in)
	// the original becomes the load: cleared first (gen.c's *in = zinst)
	copyinst(in, zinst())
	in.line = new.line
	in.pos = new.pos
	in.next = new
	in.op = op
	in.s = a
	in.sm = am
	in.dm = Afp
	in.d.reg = treg
	in.pc = pc
	in.reach = 1
	in.block = new.block
	return new
}

func rewritedestreg(in ref types.Inst, op int, treg int) ref types.Inst {
	n := zinst()
	n.next = in.next
	in.next = n
	n.line = in.line
	n.pos = in.pos
	n.op = op
	n.sm = Afp
	n.s.reg = treg
	n.d = in.m
	n.dm = in.mm
	n.reach = 1
	n.block = in.block
	in.mm = Afp
	in.m.reg = treg
	in.m.decl = nil
	return n
}
