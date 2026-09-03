module Com

import sys "sys"
import math "math"
import types "types"
import check "check"
import gen "gen"
import disw "disw"

// a port of ember/com.c: lowering of checked trees to Dis
// instructions and the .dis writer's driver, modcom().

const XMAGIC = 819248
const HASLDT = 64
const HASEXCEPT = 32
const MaxLab = 32

const Rreg = gen.Rreg
const Rmreg = gen.Rmreg
const Roff = gen.Roff
const Rnoff = gen.Rnoff
const Rdesc = gen.Rdesc
const Rdescp = gen.Rdescp
const Rconst = gen.Rconst
const Ralways = gen.Ralways
const Radr = gen.Radr
const Rmadr = gen.Rmadr
const Rcant = gen.Rcant
const Rpc = gen.Rpc
const Rmpc = gen.Rmpc
const Rareg = gen.Rareg
const Ramreg = gen.Ramreg
const Raadr = gen.Raadr
const Ramadr = gen.Ramadr
const Rldt = gen.Rldt

var infile string
var nerrors = 0
var curfn ref types.Decl
var globals ref types.Decl
var nlabel = 0
var breaks = [MaxLab]ref types.Inst
var conts = [MaxLab]ref types.Inst
var isloop = [MaxLab]int
var labels = [MaxLab]string
var labdep = 0
var excs ref types.Except	// the module's try handlers, in reverse order until modcom()
var oprelinvert = [types.Oend]int
var opcommute = [types.Oend]int
var loadedflag ref types.Decl
var nildecl ref types.Decl
var impdecl ref types.Decl

// the address of an indexed element, see indxaddr()
type Indxaddr struct {
	ind ref types.Node
	addrtmp ref types.Node
	tl ref types.Node
	tr ref types.Node
}

func usetypes(t Types) {
	types = t
	gen.usetypes(t)
	disw.usetypes(t)
}

func usecheck(c Check) {
	check = c
}

func fatal(msg string) {
	sys.fprint(sys.fildes(2), "fatal ember compiler error: %s\n", msg)
	var l list int
	hd(l)
}

func error(line int, msg string) {
	nerrors++
	sys.fprint(sys.fildes(2), "%s:%d: %s\n", infile, line, msg)
}

func tint() ref types.Type {
	return types.basic(types.Tint)
}

func tnone() ref types.Type {
	return types.basic(types.Tnone)
}

func tstring() ref types.Type {
	return types.basic(types.Tstring)
}

func tany() ref types.Type {
	return types.basic(types.Tany)
}

func lastline() int {
	return gen.lastinst().line
}

func lastpos() int {
	return gen.lastinst().pos
}

func newnode() ref types.Node {
	return types.mkn(types.Onone, nil, nil)
}

func mkname(line int, pos int, s string) ref types.Node {
	n := types.mkn(types.Oname, nil, nil)
	n.line = line
	n.pos = pos
	n.sym = s
	return n
}

func mkconst(line int, pos int, v big) ref types.Node {
	n := types.mkn(types.Oconst, nil, nil)
	n.line = line
	n.pos = pos
	n.val = v
	return n
}

func mkrconst(line int, pos int, r real) ref types.Node {
	n := types.mkn(types.Oconst, nil, nil)
	n.line = line
	n.pos = pos
	n.rval = r
	n.flags |= types.NREAL
	return n
}

func mksconst(line int, pos int, s string) ref types.Node {
	n := types.mkn(types.Oconst, nil, nil)
	n.line = line
	n.pos = pos
	n.sym = s
	n.flags |= types.NSTR
	return n
}

func bcinit() {
	oprelinvert[types.Oeq] = types.Oneq
	oprelinvert[types.Oneq] = types.Oeq
	oprelinvert[types.Olt] = types.Ogeq
	oprelinvert[types.Ogt] = types.Oleq
	oprelinvert[types.Ogeq] = types.Olt
	oprelinvert[types.Oleq] = types.Ogt

	opcommute[types.Oeq] = types.Oeq
	opcommute[types.Oneq] = types.Oneq
	opcommute[types.Olt] = types.Ogt
	opcommute[types.Ogt] = types.Olt
	opcommute[types.Ogeq] = types.Oleq
	opcommute[types.Oleq] = types.Ogeq
	opcommute[types.Oadd] = types.Oadd
	opcommute[types.Omul] = types.Omul
	opcommute[types.Oand] = types.Oand
	opcommute[types.Oor] = types.Oor
	opcommute[types.Oxor] = types.Oxor
}

func appglobal(d ref types.Decl) ref types.Decl {
	d.next = nil
	if globals == nil {
		globals = d
	} else {
		e := globals
		for e.next != nil {
			e = e.next
		}
		e.next = d
	}
	return d
}

func globalsconst(n ref types.Node) ref types.Decl {
	// an empty literal's text is nil (a nil string is the empty
	// string here), so the C check for a missing symbol has no
	// counterpart; the hidden key mirrors com.c's ".s.<text>"
	s := n.sym
	key := ".s." + s
	d := types.symdecl(key)
	if d == nil || d.store != types.Dglobal || d.ty != tstring() {
		d = types.mkdecl(n.line, n.pos, types.Dglobal, tstring())
		d.sym = s
		types.setsymdecl(key, d)
		d.init = n
		appglobal(d)
	}
	d.refs++
	n.decl = d
	n.ty = tstring()
	return d
}

func realbits(r real) big {
	b := [8]byte
	math.export_real(b, [1]real{r})
	v := big(0)
	for i := 0; i < 8; i++ {
		v = (v << 8) | big(int(b[i]))
	}
	return v
}

func globalrconst(n ref types.Node) ref types.Decl {
	s := sys.sprint(".r.%bd", realbits(n.rval))
	d := types.symdecl(s)
	if d == nil || d.store != types.Dglobal {
		d = types.mkdecl(n.line, n.pos, types.Dglobal, types.basic(types.Treal))
		d.sym = s
		types.setsymdecl(s, d)
		d.init = types.dupn(n)
		d.init.ty = types.basic(types.Treal)
		d.init.decl = d
		appglobal(d)
	}
	d.refs++
	n.decl = d
	n.addable = Rmreg
	return d
}

func globalbconst(n ref types.Node) ref types.Decl {
	s := sys.sprint(".b.%bd", n.val)
	d := types.symdecl(s)
	if d == nil || d.store != types.Dglobal {
		d = types.mkdecl(n.line, n.pos, types.Dglobal, types.basic(types.Tbig))
		d.sym = s
		types.setsymdecl(s, d)
		d.init = types.dupn(n)
		d.init.ty = types.basic(types.Tbig)
		d.init.decl = d
		appglobal(d)
	}
	d.refs++
	n.decl = d
	n.addable = Rmreg
	return d
}

func globaliconst(n ref types.Node) ref types.Decl {
	s := sys.sprint(".i.%bd", n.val)
	d := types.symdecl(s)
	if d == nil || d.store != types.Dglobal {
		d = types.mkdecl(n.line, n.pos, types.Dglobal, tint())
		d.sym = s
		types.setsymdecl(s, d)
		d.init = types.dupn(n)
		d.init.ty = tint()
		d.init.decl = d
		appglobal(d)
	}
	d.refs++
	n.decl = d
	n.addable = Rmreg
	return d
}

func sumark(n ref types.Node) ref types.Node {
	if n == nil {
		return nil
	}
	n.temps = 0
	n.addable = Rcant
	left := n.left
	right := n.right
	if left != nil {
		sumark(left)
		n.temps = left.temps
	}
	if right != nil {
		sumark(right)
		if right.temps == n.temps {
			n.temps++
		} else if right.temps > n.temps {
			n.temps = right.temps
		}
	}
	match n.op {
	case types.Oname:
		if n.decl == nil {
			fatal("sumark: Oname without decl")
		}
		match n.decl.store {
		case types.Darg, types.Dlocal:
			n.addable = Rreg
		case types.Dglobal:
			n.addable = Rmreg
		case types.Dfn:
			n.addable = Rpc
		case types.Dtype:
			n.addable = Rcant
		default:
			fatal(sys.sprint("sumark: bad store %d for %s", n.decl.store, n.decl.sym))
		}
	case types.Omdot:
		n.addable = Rmpc
	case types.Oconst:
		match n.ty.kind {
		case types.Tbyte:
			n.addable = Rconst
		case types.Tint:
			v := n.val
			if (v < big(0) && ((v >> 29) & big(7)) != big(7)) || (v > big(0) && (v >> 29) != big(0)) {
				globaliconst(n)
			} else {
				n.addable = Rconst
			}
		case types.Tstring:
			globalsconst(n)
			n.addable = Rmreg
		case types.Tbig:
			globalbconst(n)
			n.addable = Rmreg
		case types.Treal:
			globalrconst(n)
			n.addable = Rmreg
		default:
			fatal("sumark: const " + types.tprint(n.ty))
		}
	case types.Oadr:
		match left.addable {
		case Rreg:
			n.addable = Rareg
		case Rmreg:
			n.addable = Ramreg
		case Radr:
			n.addable = Raadr
		case Rmadr:
			n.addable = Ramadr
		}
	case types.Oind:
		match left.addable {
		case Rreg:
			n.addable = Radr
		case Rmreg:
			n.addable = Rmadr
		case Rareg:
			n.addable = Rreg
		case Ramreg:
			n.addable = Rmreg
		case Raadr:
			n.addable = Radr
		case Ramadr:
			n.addable = Rmadr
		}
	case types.Oadd:
		if right != nil && right.addable == Rconst {
			match left.addable {
			case Rareg:
				n.addable = Rareg
			case Ramreg:
				n.addable = Ramreg
			case Rreg:
				n.addable = Raadr
			case Rmreg:
				n.addable = Ramadr
			case Raadr:
				n.addable = Raadr
			case Ramadr:
				n.addable = Ramadr
			}
		}
	case types.Olen, types.Ocons, types.Ohd, types.Otl, types.Oindx, types.Oslice, types.Oinds, types.Oload, types.Ocast:
		n.temps++
	case types.Oarray:
		sumark(n.aux)
	}
	return n
}

func eacom(n ref types.Node, reg ref types.Node, t ref types.Node) ref types.Node {
	if n.addable < Rcant {
		return n
	}
	ty := n.ty
	if n.op == types.Oadr {
		ty = tint()
	}
	ecom(n.line, n.pos, gen.talloc(reg, ty, t), n)
	reg.line = n.line
	reg.pos = n.pos
	return reg
}

// materialize the base of a doubly indirect field access, see com.c
func fixdblind(n ref types.Node) ref types.Node {
	if n == nil || n.op != types.Oind || n.addable < Rcant || n.left == nil || n.left.op != types.Oadd {
		return nil
	}
	baseval := types.dupn(n.left.left)
	baseval.flags = n.left.left.flags
	baseval.ty = tint()
	tres := types.mkn(types.Oname, nil, nil)
	ecom(baseval.line, baseval.pos, gen.talloc(tres, tint(), nil), baseval)
	n.left.left = tres
	sumark(n)
	return tres
}

// materialize a call result whose field is being read, see com.c
func fixcallbase(n ref types.Node) ref types.Node {
	if n == nil || n.op != types.Oind || n.left == nil || n.left.op != types.Oadd {
		return nil
	}
	base := n.left.left
	if base == nil {
		return nil
	}
	inner := base
	if base.op == types.Oadr {
		inner = base.left
	}
	if inner == nil {
		return nil
	}
	match inner.op {
	case types.Ocall, types.Ohd, types.Orcv, types.Ochk:
		break
	case types.Ocomposite:
		if base.op != types.Oadr {
			return nil
		}
	case types.Oref:
		if base.op == types.Oadr {
			return nil
		}
	default:
		return nil
	}
	tres := types.mkn(types.Oname, nil, nil)
	ecom(inner.line, inner.pos, gen.talloc(tres, inner.ty, nil), inner)
	if base.op == types.Oadr {
		base.left = tres
	} else {
		n.left.left = tres
	}
	sumark(n)
	return tres
}

func indxaddr(line int, pos int, n ref types.Node) ref Indxaddr {
	ia := ref Indxaddr{ind: newnode(), addrtmp: newnode(), tl: newnode(), tr: newnode()}
	left := n.left
	right := n.right
	if right.addable < Rcant {
		if left.addable >= Rcant {
			left = eacom(left, ia.tl, nil)
		}
	} else if left.temps < right.temps {
		right = eacom(right, ia.tr, nil)
		if left.addable >= Rcant {
			left = eacom(left, ia.tl, nil)
		}
	} else {
		left = eacom(left, ia.tl, nil)
		right = eacom(right, ia.tr, nil)
	}
	op := gen.IINDX
	match n.ty.size {
	case types.IBY2LG:
		if n.ty == types.basic(types.Treal) {
			op = gen.IINDF
		} else {
			op = gen.IINDL
		}
	case 1:
		op = gen.IINDB
	default:
		op = gen.IINDX
	}
	gen.talloc(ia.addrtmp, tint(), nil)
	gen.genrawop(line, pos, op, left, ia.addrtmp, right)

	ia.ind.op = types.Oind
	ia.ind.left = ia.addrtmp
	ia.ind.line = n.line
	ia.ind.pos = n.pos
	ia.ind.ty = n.ty
	sumark(ia.ind)
	return ia
}

func indxaddrfree(ia ref Indxaddr) {
	gen.tfree(ia.tl)
	gen.tfree(ia.tr)
	gen.tfree(ia.addrtmp)
}

func callcom(line int, pos int, op int, n ref types.Node, ret ref types.Node) {
	args := n.right
	nfn := n.left
	local := 0
	match nfn.op {
	case types.Omdot:
		if nfn.addable != Rmpc {
			fatal("callcom: callee not Rmpc")
		}
	case types.Oname:
		if nfn.decl == nil || nfn.decl.store != types.Dfn {
			fatal("callcom: bad local callee")
		}
		local = 1
	default:
		fatal("callcom: unsupported callee " + types.opname(nfn.op))
	}

	if op != types.Ospawn && nfn.ty.tof != tnone() && nfn.ty.tof != nil && ret == nil {
		tmod := newnode()
		ecom(line, pos, gen.talloc(tmod, nfn.ty.tof, nil), n)
		gen.tfree(tmod)
		return
	}

	frame := newnode()
	gen.talloc(frame, tint(), nil)
	var mod ref types.Node
	var ind ref types.Node
	var tind ref types.Node
	if local == 0 {
		mod = nfn.left
		ind = nfn.right
		if mod.addable >= Rcant {
			fatal("callcom: module not addressable")
		}
		realcallee := 0
		if ind.decl != nil {
			realcallee = 1
		}
		if ind.op != types.Oname && ind.addable >= Ralways {
			tind = newnode()
			gen.talloc(tind, ind.ty, nil)
			ecom(ind.line, ind.pos, tind, ind)
			ind = tind
		} else if ind.decl != nil {
			ind.addable = Roff
		}
		if nfn.ty.varargs != 0 {
			if realcallee != 0 {
				nfn.decl = types.dupdecl(ind.decl)
			} else {
				nfn.decl = types.mkdecl(line, pos, types.Dlocal, nfn.ty)
			}
			nfn.decl.desc = types.gendesc(nfn.decl, types.idoffsets(nfn.ty.ids, types.MaxTemp, types.MaxAlign), nfn.ty.ids)
			in := gen.genrawop(line, pos, gen.IFRAME, nil, nil, frame)
			in.sm = gen.Adesc
			in.s.decl = nfn.decl
		} else {
			gen.genrawop(line, pos, gen.IMFRAME, mod, ind, frame)
		}
	} else {
		in := gen.genrawop(line, pos, gen.IFRAME, nil, nil, frame)
		in.sm = gen.Adesc
		in.s.decl = nfn.decl
	}

	toff := newnode()
	tadd := newnode()
	pass := newnode()
	toff.op = types.Oconst
	toff.addable = Rconst
	toff.ty = tint()
	tadd.op = types.Oadd
	tadd.addable = Raadr
	tadd.left = frame
	tadd.right = toff
	tadd.ty = tint()
	pass.op = types.Oind
	pass.addable = Radr
	pass.left = tadd

	d := nfn.ty.ids
	off := 0
	for a := args; a != nil; a = a.right {
		e := a
		if a.op == types.Oseq {
			e = a.left
		}
		if d == nil {
			fatal("callcom: too many args")
		}
		if (e.flags & types.NSPREAD) != 0 {
			// f(g()): the call into a tuple temporary, then each
			// field to its parameter's slot (com.c)
			tup := newnode()
			gen.talloc(tup, e.ty, nil)
			ecom(e.line, e.pos, tup, e)
			for fd := e.ty.ids; fd != nil; fd = fd.next {
				if d == nil {
					fatal("callcom: too many spread args")
				}
				adr := types.mkn(types.Oadr, types.dupn(tup), nil)
				adr.line = e.line
				adr.pos = e.pos
				adr.ty = e.ty
				foff := mkconst(e.line, e.pos, big(fd.offset))
				foff.ty = tint()
				faddr := types.mkn(types.Oadd, adr, foff)
				faddr.line = e.line
				faddr.pos = e.pos
				faddr.ty = tint()
				find := types.mkn(types.Oind, faddr, nil)
				find.line = e.line
				find.pos = e.pos
				find.ty = fd.ty
				sumark(find)
				off = d.offset
				toff.val = big(off)
				pass.ty = d.ty
				ecom(e.line, e.pos, pass, find)
				d = d.next
			}
			gen.tfree(tup)
			break
		}
		off = d.offset
		toff.val = big(off)
		pass.ty = d.ty
		ecom(e.line, e.pos, pass, e)
		d = d.next
		if a.op != types.Oseq {
			break
		}
	}
	if off > gen.maxstack() {
		gen.setmaxstack(off)
	}

	if ret != nil {
		toff.val = big(gen.REGRET * types.IBY2WD)
		pass.ty = nfn.ty.tof
		gen.genrawop(line, pos, gen.ILEA, ret, nil, pass)
	}

	if local != 0 {
		iop := gen.ICALL
		if op == types.Ospawn {
			iop = gen.ISPAWN
		}
		in := gen.genrawop(line, pos, iop, frame, nil, nil)
		in.d.decl = nfn.decl
		in.dm = gen.Apc
	} else {
		iop := gen.IMCALL
		if op == types.Ospawn {
			iop = gen.IMSPAWN
		}
		gen.genrawop(line, pos, iop, frame, ind, mod)
	}
	if tind != nil && ind == tind {
		gen.tfree(tind)
	}
	gen.tfree(frame)
}

// a call through a function value, see com.c's fpcall()
func fpcall(line int, pos int, op int, n ref types.Node, nto ref types.Node) {
	tp := newnode()
	calleety := n.left.ty
	e := n.left.left
	if e.addable == Radr || e.addable == Rmadr || e.addable >= Rcant {
		ecom(e.line, e.pos, gen.talloc(tp, e.ty, nil), e)
		tp.line = e.line
		tp.pos = e.pos
		e = tp
	}
	mod := types.mkunary(types.Oind, e)
	ind := types.mkunary(types.Oind, types.mkbin(types.Oadd, types.dupn(e), mkconst(line, pos, big(types.IBY2WD))))
	env := types.mkunary(types.Oind, types.mkbin(types.Oadd, types.dupn(e), mkconst(line, pos, big(2 * types.IBY2WD))))
	n.left = types.mkbin(types.Omdot, mod, ind)
	n.left.ty = calleety
	n.right = types.mkseq(env, n.right)
	mod.ty = tint()
	ind.ty = tint()
	ind.left.ty = tint()
	ind.left.right.ty = tint()
	env.ty = tany()
	env.left.ty = tint()
	env.left.right.ty = tint()
	sumark(n)
	callcom(line, pos, op, n, nto)
	gen.tfree(tp)
}

func bcom(n ref types.Node, iftrue int, b ref types.Inst) ref types.Inst {
	left := n.left
	right := n.right
	op := n.op

	match op {
	case types.Onot:
		return bcom(n.left, 1 - iftrue, b)
	case types.Oandand:
		if iftrue == 0 {
			bb := bcom(n.left, 1, nil)
			b = bcom(n.right, 0, b)
			gen.patch(bb, gen.nextinst())
			return b
		}
		b = bcom(n.left, 1, b)
		b = bcom(n.right, 1, b)
		return b
	case types.Ooror:
		if iftrue == 0 {
			b = bcom(n.left, 0, b)
			b = bcom(n.right, 0, b)
			return b
		}
		bb := bcom(n.left, 0, nil)
		b = bcom(n.right, 1, b)
		gen.patch(bb, gen.nextinst())
		return b
	case types.Ogt, types.Ogeq, types.Oneq, types.Oeq, types.Olt, types.Oleq:
		break
	default:
		if n.ty != nil && n.ty.kind == types.Tint {
			right = mkconst(n.line, n.pos, big(0))
			right.ty = tint()
			right.addable = Rconst
			left = n
			op = types.Oneq
		} else {
			fatal("bcom: can't test " + types.opname(n.op))
			return b
		}
	}

	if iftrue != 0 {
		op = oprelinvert[op]
	}

	if left.addable < right.addable {
		t := left
		left = right
		right = t
		op = opcommute[op]
	}

	tl := newnode()
	tr := newnode()
	if right.addable < Ralways {
		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}
	} else if left.temps <= right.temps {
		right = ecom(right.line, right.pos, gen.talloc(tr, right.ty, nil), right)
		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}
	} else {
		left = eacom(left, tl, nil)
		right = ecom(right.line, right.pos, gen.talloc(tr, right.ty, nil), right)
	}
	bb := gen.genbra(n.line, n.pos, op, left, right)
	bb.branch = b
	gen.tfree(tl)
	gen.tfree(tr)
	return bb
}

func compositexhaustive(composite ref types.Node) int {
	t := composite.ty
	if t == nil || t.kind != types.Tadt {
		return 0
	}
	nset := 0
	for p := composite.right; p != nil; p = p.right {
		e := p
		if p.op == types.Oseq {
			e = p.left
		}
		if e.decl != nil {
			nset++
			if e.right.op == types.Ocomposite && compositexhaustive(e.right) == 0 {
				return 0
			}
		}
		if p.op != types.Oseq {
			break
		}
	}
	nfields := 0
	for fd := t.ids; fd != nil; fd = fd.next {
		nfields++
	}
	if nset == nfields {
		return 1
	}
	return 0
}

func storecomposite(line int, pos int, base ref types.Node, composite ref types.Node) {
	if composite.ty.kind == types.Tadtpick {
		off := mkconst(composite.line, composite.pos, big(0))
		off.ty = tint()
		addr := types.mkn(types.Oadd, types.dupn(base), off)
		addr.line = composite.line
		addr.pos = composite.pos
		addr.ty = tint()
		ind := types.mkn(types.Oind, addr, nil)
		ind.line = composite.line
		ind.pos = composite.pos
		ind.ty = tint()
		sumark(ind)
		tagval := mkconst(composite.line, composite.pos, big(composite.ty.decl.tag))
		tagval.ty = tint()
		sumark(tagval)
		ecom(line, pos, ind, tagval)
	}
	for p := composite.right; p != nil; p = p.right {
		e := p
		if p.op == types.Oseq {
			e = p.left
		}
		if e.decl != nil {
			off := mkconst(e.line, e.pos, big(e.decl.offset))
			off.ty = tint()
			addr := types.mkn(types.Oadd, types.dupn(base), off)
			addr.line = e.line
			addr.pos = e.pos
			addr.ty = tint()
			if e.right.op == types.Ocomposite {
				storecomposite(line, pos, addr, e.right)
			} else {
				sumark(e.right)
				ind := types.mkn(types.Oind, addr, nil)
				ind.line = e.line
				ind.pos = e.pos
				ind.ty = e.decl.ty
				sumark(ind)
				ecom(line, pos, ind, e.right)
			}
		}
		if p.op != types.Oseq {
			break
		}
	}
}

func storecompositezero(line int, pos int, dst ref types.Node, composite ref types.Node) {
	rt := types.mktype(line, pos, types.Tref, dst.ty, nil)
	types.sizetype(rt)
	tmp := newnode()
	gen.talloc(tmp, rt, nil)
	gen.genrawop(line, pos, gen.INEWZ, gen.mktn(dst.ty), nil, tmp)
	storecomposite(line, pos, tmp, composite)

	ind := newnode()
	ind.op = types.Oind
	ind.left = tmp
	ind.ty = dst.ty
	sumark(ind)
	gen.genmove(line, pos, gen.Mas, dst.ty, ind, dst)
	gen.tfree(tmp)
}

func destructure(line int, pos int, lhs ref types.Node, rhs ref types.Node) {
	sumark(rhs)
	tuptemp := newnode()
	gen.talloc(tuptemp, rhs.ty, nil)
	ecom(line, pos, tuptemp, rhs)

	fd := rhs.ty.ids
	for p := lhs; p != nil; p = p.right {
		id := p
		if p.op == types.Oseq {
			id = p.left
		}
		sumark(id)
		isindx := 0
		if id.op == types.Oindx {
			isindx = 1
		}
		var fixid ref types.Node
		var fixcb ref types.Node
		var ia ref Indxaddr
		if isindx != 0 {
			ia = indxaddr(id.line, id.pos, id)
		} else {
			fixcb = fixcallbase(id)
			fixid = fixdblind(id)
		}
		adr := types.mkn(types.Oadr, types.dupn(tuptemp), nil)
		adr.line = id.line
		adr.pos = id.pos
		adr.ty = rhs.ty
		off := mkconst(id.line, id.pos, big(fd.offset))
		off.ty = tint()
		addr := types.mkn(types.Oadd, adr, off)
		addr.line = id.line
		addr.pos = id.pos
		addr.ty = tint()
		sumark(addr)
		ind := types.mkn(types.Oind, addr, nil)
		ind.line = id.line
		ind.pos = id.pos
		ind.ty = fd.ty
		sumark(ind)
		if isindx != 0 {
			ecom(id.line, id.pos, ia.ind, ind)
			indxaddrfree(ia)
		} else {
			ecom(id.line, id.pos, id, ind)
			gen.tfree(fixid)
			gen.tfree(fixcb)
		}
		fd = fd.next
		if p.op != types.Oseq {
			break
		}
	}
	gen.tfree(tuptemp)
}

// a function used as a value: build its tfnptr, see com.c's Oname case
func fnvalue(line int, pos int, nto ref types.Node, n ref types.Node, tres ref types.Node) ref types.Node {
	d := n.decl
	wd := d.wrapdecl
	if wd == nil {
		fatal(sys.sprint("ecom: %s has no function-value wrapper", d.sym))
	}
	dst := nto
	if dst == nil || (dst.addable != Rreg && dst.addable != Rmreg) {
		dst = gen.talloc(tres, n.ty, nil)
	}
	gen.genrawop(line, pos, gen.INEWZ, gen.mktn(types.tfnptrt()), nil, dst)

	ind0 := newnode()
	ind0.op = types.Oind
	ind0.left = types.dupn(dst)
	ind0.ty = tany()
	sumark(ind0)
	gen.genrawop(line, pos, gen.ISELF, nil, nil, ind0)

	off := newnode()
	off.op = types.Oconst
	off.val = big(types.IBY2WD)
	off.ty = tint()
	sumark(off)
	addr := newnode()
	addr.op = types.Oadd
	addr.left = types.dupn(dst)
	addr.right = off
	addr.ty = tint()
	sumark(addr)
	ind1 := newnode()
	ind1.op = types.Oind
	ind1.left = addr
	ind1.ty = tint()
	sumark(ind1)

	tfn := newnode()
	tfn.op = types.Oname
	tfn.decl = wd
	tfn.sym = wd.sym
	tfn.ty = tint()
	tfn.addable = Rnoff
	gen.genmove(line, pos, gen.Mas, tint(), tfn, ind1)

	if d.captures != nil {
		captref := types.mktype(line, pos, types.Tref, d.capty, nil)
		types.sizetype(captref)

		capinst := newnode()
		gen.talloc(capinst, captref, nil)
		gen.genrawop(line, pos, gen.INEWZ, gen.mktn(d.capty), nil, capinst)

		fd := d.capty.ids
		for cl := d.captures; cl != nil; cl = tl(cl) {
			cd := hd(cl)
			foff := mkconst(line, pos, big(fd.offset))
			foff.ty = tint()
			faddr := types.mkn(types.Oadd, types.dupn(capinst), foff)
			faddr.line = line
			faddr.pos = pos
			faddr.ty = tint()

			var val ref types.Node
			if check.declownedby(cd, d.enclosing) != 0 {
				val = mkname(line, pos, cd.sym)
				val.decl = cd
				val.ty = cd.ty
				sumark(val)
			} else {
				efd := d.enclosing.capty.ids
				ecap := d.enclosing.captures
				for ecap != nil {
					if hd(ecap) == cd {
						break
					}
					ecap = tl(ecap)
					efd = efd.next
				}
				if ecap == nil {
					fatal(sys.sprint("ecom: %s captured through %s with no forwarding capture", cd.sym, d.enclosing.sym))
				}

				envref := mkname(line, pos, d.enclosing.ty.ids.sym)
				envref.decl = d.enclosing.ty.ids
				envrefty := types.mktype(line, pos, types.Tref, d.enclosing.capty, nil)
				types.sizetype(envrefty)
				envref.ty = envrefty

				eoff := mkconst(line, pos, big(efd.offset))
				eoff.ty = tint()
				eaddr := types.mkn(types.Oadd, envref, eoff)
				eaddr.line = line
				eaddr.pos = pos
				eaddr.ty = tint()

				val = types.mkn(types.Oind, eaddr, nil)
				val.line = line
				val.pos = pos
				val.ty = efd.ty
				sumark(val)
			}

			find := types.mkn(types.Oind, faddr, nil)
			find.line = line
			find.pos = pos
			find.ty = fd.ty
			sumark(find)

			ecom(line, pos, find, val)
			fd = fd.next
		}

		off2 := newnode()
		off2.op = types.Oconst
		off2.val = big(2 * types.IBY2WD)
		off2.ty = tint()
		sumark(off2)
		addr2 := newnode()
		addr2.op = types.Oadd
		addr2.left = types.dupn(dst)
		addr2.right = off2
		addr2.ty = tint()
		sumark(addr2)
		ind2 := newnode()
		ind2.op = types.Oind
		ind2.left = addr2
		ind2.ty = captref
		sumark(ind2)

		gen.genmove(line, pos, gen.Mas, captref, capinst, ind2)
		gen.tfree(capinst)
	}

	if nto != nil && nto != dst {
		gen.genmove(line, pos, gen.Mas, n.ty, dst, nto)
		gen.tfree(tres)
	}
	if nto != nil {
		return nto
	}
	return dst
}

func ecom(line int, pos int, nto ref types.Node, n ref types.Node) ref types.Node {
	if n == nil {
		return nil
	}
	tl := newnode()
	tr := newnode()
	tres := newnode()
	left := n.left
	right := n.right

	match n.op {
	case types.Oname:
		if n.decl != nil && n.decl.store == types.Dfn {
			return fnvalue(line, pos, nto, n, tres)
		}
		if nto != nil {
			gen.genmove(line, pos, gen.Mas, n.ty, n, nto)
		}
		return nto
	case types.Oconst:
		if nto != nil {
			gen.genmove(line, pos, gen.Mas, n.ty, n, nto)
		}
		return nto
	case types.Ocall:
		if left.op == types.Oind {
			fpcall(line, pos, types.Ocall, n, nto)
		} else {
			callcom(line, pos, types.Ocall, n, nto)
		}
		return nto
	case types.Ospawn:
		if left.left.op == types.Oind {
			fpcall(line, pos, types.Ospawn, left, nto)
		} else {
			callcom(line, pos, types.Ospawn, left, nto)
		}
		return nto
	case types.Ocomposite:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if compositexhaustive(n) != 0 && (nto.addable == Rreg || nto.addable == Rmreg) {
			adr := types.mkn(types.Oadr, types.dupn(nto), nil)
			adr.line = line
			adr.pos = pos
			adr.ty = n.ty
			storecomposite(line, pos, adr, n)
		} else {
			storecompositezero(line, pos, nto, n)
		}
		return nto
	case types.Ocast:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		ft := left.ty
		if types.tequal(ft, n.ty) != 0 {
			gen.genmove(line, pos, gen.Mas, n.ty, left, nto)
		} else {
			tmid := newnode()
			mid := left
			via := types.castvia(ft, n.ty)
			if via != nil {
				mid = gen.talloc(tmid, via, nil)
				gen.genrawop(line, pos, types.castop(ft, via), left, nil, mid)
				ft = via
			}
			op := types.castop(ft, n.ty)
			if op == 0 {
				fatal(sys.sprint("ecom: no conversion from %s to %s", types.tprint(ft), types.tprint(n.ty)))
			}
			gen.genrawop(line, pos, op, mid, nil, nto)
			gen.tfree(tmid)
		}
		gen.tfree(tl)
		return nto
	case types.Oload:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if right.addable >= Rcant {
			right = eacom(right, tr, nil)
		}
		iface := modiface(n.decl)
		if iface == nil {
			return nto
		}
		ifn := newnode()
		ifn.op = types.Oname
		ifn.decl = iface
		ifn.ty = iface.ty
		ifn.addable = Rldt
		ifn.line = line
		ifn.pos = pos
		gen.genrawop(line, pos, gen.ILOAD, right, ifn, nto)
		gen.tfree(tr)
		return nto
	case types.Ochan:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if left == nil {
			left = mkconst(line, pos, big(0))
			left.ty = tint()
			sumark(left)
		} else if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		gen.genchan(line, pos, left, n.ty.tof, nto)
		gen.tfree(tl)
		return nto
	case types.Oarray:
		if nto == nil {
			fatal("ecom: array without destination")
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		gen.genrawop(line, pos, gen.INEWAZ, left, gen.mktn(n.ty.tof), nto)
		gen.tfree(tl)
		if n.aux != nil {
			i := 0
			for p := n.aux; p != nil; p = p.right {
				e := p
				if p.op == types.Oseq {
					e = p.left
				}
				idx := mkconst(e.line, e.pos, big(i))
				idx.ty = tint()
				sumark(idx)
				fake := newnode()
				fake.op = types.Oindx
				fake.left = nto
				fake.right = idx
				fake.ty = n.ty.tof
				fake.line = e.line
				fake.pos = e.pos
				ia := indxaddr(e.line, e.pos, fake)
				ecom(e.line, e.pos, ia.ind, e.right)
				indxaddrfree(ia)
				i++
				if p.op != types.Oseq {
					break
				}
			}
		}
		return nto
	case types.Osnd:
		if right.addable < Rcant {
			if left.addable >= Rcant {
				left = eacom(left, tl, nto)
			}
		} else if left.temps < right.temps {
			right = eacom(right, tr, nto)
			if left.addable >= Rcant {
				left = eacom(left, tl, nil)
			}
		} else {
			left = eacom(left, tl, nto)
			right = eacom(right, tr, nil)
		}
		gen.genrawop(n.line, n.pos, gen.ISEND, right, nil, left)
		gen.tfree(tl)
		gen.tfree(tr)
		return nto
	case types.Oraise:
		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}
		gen.genrawop(line, pos, gen.IRAISE, left, nil, nil)
		gen.tfree(tl)
		return nto
	case types.Orcv:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		gen.genrawop(line, pos, gen.IRECV, left, nil, nto)
		gen.tfree(tl)
		return nto
	case types.Oind:
		fcb := fixcallbase(n)
		fd := fixdblind(n)
		if left.addable >= Rcant && left.addable != Rareg && left.addable != Ramreg && left.addable != Raadr && left.addable != Ramadr {
			left = eacom(left, tl, nil)
		}
		if nto != nil {
			gen.genmove(line, pos, gen.Mas, n.ty, n, nto)
		}
		gen.tfree(tl)
		gen.tfree(fd)
		gen.tfree(fcb)
		return nto
	case types.Olen:
		if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		if nto == nil {
			fatal("ecom: len without destination")
		}
		match left.ty.kind {
		case types.Tarray:
			gen.genrawop(line, pos, gen.ILENA, left, nil, nto)
		case types.Tstring:
			gen.genrawop(line, pos, gen.ILENC, left, nil, nto)
		case types.Tlist:
			gen.genrawop(line, pos, gen.ILENL, left, nil, nto)
		default:
			fatal("ecom: len of " + types.tprint(left.ty))
		}
		gen.tfree(tl)
		return nto
	case types.Oinds:
		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}
		if right.addable >= Ralways {
			right = ecom(right.line, right.pos, gen.talloc(tr, right.ty, nil), right)
		}
		if nto == nil {
			fatal("ecom: inds without destination")
		}
		gen.genop(line, pos, types.Oinds, left, right, nto)
		gen.tfree(tl)
		gen.tfree(tr)
		return nto
	case types.Oindx:
		if nto == nil {
			fatal("ecom: indx without destination")
		}
		ia := indxaddr(line, pos, n)
		gen.genmove(line, pos, gen.Mas, ia.ind.ty, ia.ind, nto)
		indxaddrfree(ia)
		return nto
	case types.Oslice:
		if nto == nil {
			fatal("ecom: slice without destination")
		}
		lo := right.left
		hi := right.right

		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}

		if lo == nil {
			lo = mkconst(n.line, n.pos, big(0))
			lo.ty = tint()
			sumark(lo)
		}
		if lo.addable >= Rcant {
			lo = eacom(lo, tr, nil)
		}

		var tn ref types.Node
		if hi == nil {
			tn = types.mkn(types.Olen, left, nil)
			tn.line = n.line
			tn.pos = n.pos
			tn.ty = tint()
			sumark(tn)
		} else {
			tn = hi
		}
		ttn := newnode()
		tn = ecom(tn.line, tn.pos, gen.talloc(ttn, tint(), nil), tn)

		op := gen.ISLICEA
		if left.ty.kind == types.Tstring {
			op = gen.ISLICEC
		}
		gen.genmove(line, pos, gen.Mas, left.ty, left, nto)
		gen.genrawop(line, pos, op, lo, tn, nto)

		gen.tfree(tl)
		gen.tfree(tr)
		gen.tfree(ttn)
		return nto
	case types.Ocons:
		if nto == nil {
			fatal("ecom: cons without destination")
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}
		tto := newnode()
		ecom(right.line, right.pos, gen.talloc(tto, n.ty, nto), right)
		gen.genmove(line, pos, gen.Mcons, left.ty, left, tto)
		gen.genmove(line, pos, gen.Mas, nto.ty, tto, nto)
		gen.tfree(tl)
		gen.tfree(tto)
		return nto
	case types.Ohd:
		if nto == nil {
			fatal("ecom: hd without destination")
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		gen.genmove(line, pos, gen.Mhd, nto.ty, left, nto)
		gen.tfree(tl)
		return nto
	case types.Otl:
		if nto == nil {
			fatal("ecom: tl without destination")
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nto)
		}
		gen.genmove(line, pos, gen.Mtl, left.ty, left, nto)
		gen.tfree(tl)
		return nto
	case types.Oneg, types.Oinv:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if left.addable >= Rcant {
			left = eacom(left, tl, nil)
		}
		if n.op == types.Oneg {
			z := mkconst(line, pos, big(0))
			z.ty = n.ty
			sumark(z)
			gen.genop(line, pos, types.Osub, left, z, nto)
		} else {
			z := mkconst(line, pos, big(-1))
			z.ty = n.ty
			sumark(z)
			gen.genop(line, pos, types.Oxor, left, z, nto)
		}
		gen.tfree(tl)
		return nto
	case types.Oadd, types.Osub, types.Omul, types.Odiv, types.Omod, types.Oand, types.Oor, types.Oxor, types.Olsh, types.Orsh:
		if nto == nil {
			nto = gen.talloc(tres, n.ty, nil)
		}
		if left.addable < Ralways {
			if right.addable >= Rcant {
				right = eacom(right, tr, nto)
			}
		} else if right.temps <= left.temps {
			left = ecom(left.line, left.pos, gen.talloc(tl, left.ty, nto), left)
			if right.addable >= Rcant {
				right = eacom(right, tr, nil)
			}
		} else {
			right = eacom(right, tr, nto)
			left = ecom(left.line, left.pos, gen.talloc(tl, left.ty, nil), left)
		}
		gen.genop(line, pos, n.op, right, left, nto)
		gen.tfree(tl)
		gen.tfree(tr)
		return nto
	case types.Onot, types.Oeq, types.Oneq, types.Olt, types.Oleq, types.Ogt, types.Ogeq, types.Oandand, types.Ooror:
		if nto == nil {
			nto = gen.talloc(tres, tint(), nil)
		}
		one := mkconst(line, pos, big(1))
		one.ty = tint()
		zero := mkconst(line, pos, big(0))
		zero.ty = tint()
		p := bcom(n, 1, nil)
		gen.genmove(line, pos, gen.Mas, tint(), sumark(one), nto)
		pp := gen.genrawop(line, pos, gen.IJMP, nil, nil, nil)
		gen.patch(p, gen.nextinst())
		gen.genmove(line, pos, gen.Mas, tint(), sumark(zero), nto)
		gen.patch(pp, gen.nextinst())
		return nto
	case types.Ochk:
		tagtmp := newnode()
		tret2 := newnode()

		subj := left
		sumark(subj)
		if subj.addable >= Rcant {
			subj = eacom(subj, tl, nil)
		}

		off := mkconst(line, pos, big(0))
		off.ty = tint()
		addr := types.mkn(types.Oadd, types.dupn(subj), off)
		addr.line = line
		addr.pos = pos
		addr.ty = tint()
		tagread := types.mkn(types.Oind, addr, nil)
		tagread.line = line
		tagread.pos = pos
		tagread.ty = tint()
		sumark(tagread)
		tagval := ecom(line, pos, gen.talloc(tagtmp, tint(), nil), tagread)

		p := bcom(tagval, 0, nil)
		gen.tfree(tagtmp)

		fd := n.decl
		if fd != nil {
			if nto == nil {
				nto = gen.talloc(tres, n.ty, nil)
			}
			boff := mkconst(line, pos, big(fd.offset))
			boff.ty = tint()
			baddr := types.mkn(types.Oadd, types.dupn(subj), boff)
			baddr.line = line
			baddr.pos = pos
			baddr.ty = tint()
			bind := types.mkn(types.Oind, baddr, nil)
			bind.line = line
			bind.pos = pos
			bind.ty = fd.ty
			sumark(bind)
			ecom(line, pos, nto, bind)
		}
		pp := gen.genrawop(line, pos, gen.IJMP, nil, nil, nil)

		gen.patch(p, gen.nextinst())
		ecom(line, pos, gen.retalloc(tret2, n.left), types.dupn(subj))
		gen.genrawop(line, pos, gen.IRET, nil, nil, nil)

		gen.patch(pp, gen.nextinst())
		gen.tfree(tl)
		return nto
	case types.Oref:
		at := left.ty
		dst := nto
		if dst == nil || (dst.addable != Rreg && dst.addable != Rmreg) {
			dst = gen.talloc(tres, n.ty, nil)
		}
		gen.genrawop(line, pos, gen.INEWZ, gen.mktn(at), nil, dst)
		if left.op == types.Ocomposite {
			storecomposite(line, pos, dst, left)
		}
		if nto != nil && nto != dst {
			gen.genmove(line, pos, gen.Mas, n.ty, dst, nto)
			gen.tfree(tres)
		}
		if nto != nil {
			return nto
		}
		return dst
	case types.Otuple:
		base := nto
		if base != nil {
			if base.op == types.Oind {
				base = base.left
			} else {
				adr := types.mkunary(types.Oadr, types.dupn(base))
				adr.line = base.line
				adr.pos = base.pos
				adr.ty = base.ty
				sumark(adr)
				base = adr
			}
		}
		fd := n.ty.ids
		for p := n.left; p != nil; p = p.right {
			e := p
			if p.op == types.Oseq {
				e = p.left
			}
			if fd != nil && base != nil {
				sumark(e)
				off := mkconst(e.line, e.pos, big(fd.offset))
				off.ty = tint()
				addr := types.mkn(types.Oadd, types.dupn(base), off)
				addr.line = e.line
				addr.pos = e.pos
				addr.ty = tint()
				sumark(addr)
				ind := types.mkn(types.Oind, addr, nil)
				ind.line = e.line
				ind.pos = e.pos
				ind.ty = fd.ty
				sumark(ind)
				ecom(e.line, e.pos, ind, e)
				fd = fd.next
			}
			if p.op != types.Oseq {
				break
			}
		}
		return nto
	case types.Oadr:
		if left.op == types.Oindx {
			if nto == nil {
				fatal("ecom: adr(indx) without destination")
			}
			ia := indxaddr(line, pos, left)
			gen.genmove(line, pos, gen.Mas, tint(), ia.addrtmp, nto)
			indxaddrfree(ia)
			return nto
		}
		if left.op == types.Oind {
			// the address of a value reached through a computed
			// address is that address itself (com.c)
			if nto == nil {
				fatal("ecom: adr(ind) without destination")
			}
			ecom(line, pos, nto, left.left)
			return nto
		}
		fatal("ecom: unsupported adr base " + types.opname(left.op))
	default:
		fatal("ecom: unsupported " + types.opname(n.op))
	}
	return nto
}

func labeldepth(n ref types.Node) int {
	iscont := 0
	if n.op == types.Ocont {
		iscont = 1
	}
	if n.left == nil {
		for i := labdep - 1; i >= 0; i-- {
			if iscont == 0 || isloop[i] != 0 {
				return i
			}
		}
		if iscont != 0 {
			error(n.line, "continue outside loop")
		} else {
			error(n.line, "break outside loop")
		}
		return -1
	}
	for i := labdep - 1; i >= 0; i-- {
		if labels[i] == n.left.sym {
			if iscont != 0 && isloop[i] == 0 {
				error(n.line, sys.sprint("continue label %s is not a loop", n.left.sym))
				return -1
			}
			return i
		}
	}
	error(n.line, sys.sprint("label %s not found", n.left.sym))
	return -1
}

// a break or continue: a jump chained onto the pending list for its depth
func bccom(n ref types.Node, isbreak int, d int) {
	if labdep <= 0 {
		error(n.line, "break/continue outside loop")
		return
	}
	p := gen.genrawop(n.line, n.pos, gen.IJMP, nil, nil, nil)
	if isbreak != 0 {
		p.branch = breaks[d]
		breaks[d] = p
	} else {
		p.branch = conts[d]
		conts[d] = p
	}
}

func findlab(ty ref types.Type, v ref types.Node, labs []ref types.Label, nlab int) int {
	if nlab <= 1 {
		return 0
	}
	if ty == tstring() {
		l := 0
		r := nlab - 1
		for l <= r {
			m := (r + l) / 2
			if labs[m].start.sym == v.sym {
				return m
			}
			if labs[m].start.sym < v.sym {
				l = m + 1
			} else {
				r = m - 1
			}
		}
		fatal("findlab: string label not found")
		return 0
	}
	l := 1
	r := nlab - 1
	for l <= r {
		m := (r + l) / 2
		if labs[m].start.val <= v.val {
			l = m + 1
		} else {
			r = m - 1
		}
	}
	m := l - 1
	if labs[m].start.val > v.val || labs[m].stop.val < v.val {
		fatal("findlab out of range")
	}
	return m
}

func altcom(nalt ref types.Node) {
	talt := nalt.ty
	c := talt.cse
	nlab := c.nlab
	nsnd := c.nsnd
	labs := c.labs
	tmps := [nlab + 1]ref types.Node
	for i := 0; i <= nlab; i++ {
		tmps[i] = newnode()
	}

	which := newnode()
	tab := newnode()
	gen.talloc(which, tint(), nil)
	gen.talloc(tab, talt, nil)

	off := newnode()
	off.op = types.Oconst
	off.ty = tint()
	off.addable = Rconst
	adr := newnode()
	adr.op = types.Oadr
	adr.left = tab
	adr.ty = tint()
	add := newnode()
	add.op = types.Oadd
	add.left = adr
	add.right = off
	add.ty = tint()
	slot := newnode()
	slot.op = types.Oind
	slot.left = add
	slot.ty = tint()
	slot.line = nalt.line
	slot.pos = nalt.pos
	sumark(slot)

	is := 2 * types.IBY2WD
	ir := is + nsnd * 2 * types.IBY2WD
	i := 0
	for n := nalt.right; n != nil; {
		arm := n
		if n.op == types.Oseq {
			arm = n.left
			n = n.right
		} else {
			n = nil
		}
		comm := arm.aux
		if comm == nil {
			continue
		}
		g := arm.left
		if comm.op == types.Osnd {
			off.val = big(is)
			is += 2 * types.IBY2WD
		} else {
			off.val = big(ir)
			ir += 2 * types.IBY2WD
		}
		lab := labs[(int(off.val) - 2 * types.IBY2WD) / (2 * types.IBY2WD)]

		ch := comm.left
		sumark(ch)
		slot.ty = ch.ty
		ecom(ch.line, ch.pos, slot, ch)
		slot.ty = tint()
		lab.isptr = 1
		off.val += big(types.IBY2WD)

		var target ref types.Node
		if comm.op == types.Osnd {
			v := comm.right
			sumark(v)
			if v.addable < Rcant {
				target = v
			} else {
				target = ecom(v.line, v.pos, gen.talloc(tmps[i], v.ty, nil), v)
			}
		} else {
			match g.op {
			case types.Odas, types.Oas:
				target = g.left
				sumark(target)
				if target.addable >= Rcant {
					fatal("altcom: receive target not addressable")
				}
			default:
				target = gen.talloc(tmps[i], comm.ty, nil)
			}
		}
		gen.genrawop(comm.line, comm.pos, gen.ILEA, target, nil, slot)
		i++
	}

	nsndc := mkconst(nalt.line, nalt.pos, big(nsnd))
	nsndc.ty = tint()
	nrcvc := mkconst(nalt.line, nalt.pos, big(nlab - nsnd))
	nrcvc.ty = tint()
	off.val = big(0)
	gen.genmove(nalt.line, nalt.pos, gen.Mas, tint(), sumark(nsndc), slot)
	off.val = big(types.IBY2WD)
	gen.genmove(nalt.line, nalt.pos, gen.Mas, tint(), sumark(nrcvc), slot)

	altop := gen.IALT
	if c.wild != nil {
		altop = gen.INBALT
	}
	gen.genrawop(nalt.line, nalt.pos, altop, tab, nil, which)

	d := types.mkdecl(nalt.line, nalt.pos, types.Dglobal, types.mktype(nalt.line, nalt.pos, types.Tgoto, nil, nil))
	d.sym = sys.sprint(".g%d", nlabel)
	nlabel++
	d.ty.cse = c
	nto := newnode()
	nto.op = types.Oname
	nto.addable = Rmreg
	nto.ty = d.ty
	nto.decl = d
	nto.line = nalt.line
	nto.pos = nalt.pos
	d.init = types.dupn(nto)
	me := gen.genrawop(nalt.line, nalt.pos, gen.IGOTO, which, nil, nto)
	me.d.reg = types.IBY2WD
	gen.tfree(tab)
	gen.tfree(which)

	var jmps ref types.Inst
	var wild ref types.Inst
	is = 0
	ir = nsnd
	i = 0
	for n := nalt.right; n != nil; {
		arm := n
		if n.op == types.Oseq {
			arm = n.left
			n = n.right
		} else {
			n = nil
		}
		j := gen.nextinst()
		comm := arm.aux
		if comm == nil {
			wild = j
		} else {
			if comm.op == types.Osnd {
				labs[is].inst = j
				is++
			} else {
				labs[ir].inst = j
				ir++
			}
			gen.tfree(tmps[i])
			i++
		}
		scom(arm.right)
		j = gen.genrawop(lastline(), lastpos(), gen.IJMP, nil, nil, nil)
		j.branch = jmps
		jmps = j
	}
	gen.patch(jmps, gen.nextinst())
	c.iwild = wild
	types.sizetype(d.ty)
	appglobal(d)
}

func nextpat(pp ref types.Node) (ref types.Node, ref types.Node) {
	n := pp
	if n == nil {
		return nil, nil
	}
	if n.op == types.Oseq {
		return n.left, n.right
	}
	return n, nil
}

func casecom(cn ref types.Node) {
	c := cn.ty.cse
	d := types.mkdecl(cn.line, cn.pos, types.Dglobal, cn.ty)
	d.sym = sys.sprint(".c%d", nlabel)
	nlabel++
	nto := newnode()
	nto.op = types.Oname
	nto.addable = Rmreg
	nto.ty = d.ty
	nto.decl = d
	nto.line = cn.line
	nto.pos = cn.pos
	d.init = types.dupn(nto)

	tmp := newnode()
	left := cn.left
	sumark(left)
	ctype := left.ty
	if left.addable >= Rcant {
		left = eacom(left, tmp, nil)
	}

	var subjbase ref types.Node
	dispatch := left
	tagtmp := newnode()
	if c.tagof != nil {
		base := left
		if ctype.kind != types.Tref {
			adr := types.mkunary(types.Oadr, types.dupn(base))
			adr.line = cn.line
			adr.pos = cn.pos
			adr.ty = ctype
			base = adr
		}
		subjbase = base
		off := mkconst(cn.line, cn.pos, big(0))
		off.ty = tint()
		addr := types.mkn(types.Oadd, types.dupn(base), off)
		addr.line = cn.line
		addr.pos = cn.pos
		addr.ty = tint()
		tagread := types.mkn(types.Oind, addr, nil)
		tagread.line = cn.line
		tagread.pos = cn.pos
		tagread.ty = tint()
		sumark(tagread)
		dispatch = ecom(cn.line, cn.pos, gen.talloc(tagtmp, tint(), nil), tagread)
	}

	labs := c.labs
	nlab := c.nlab
	cop := gen.ICASE
	if cn.ty.kind == types.Tcasec {
		cop = gen.ICASEC
	}
	gen.genrawop(dispatch.line, dispatch.pos, cop, dispatch, nil, nto)
	if subjbase == nil {
		gen.tfree(tmp)
	}
	gen.tfree(tagtmp)

	var jmps ref types.Inst
	var wild ref types.Inst
	for n := cn.right; n != nil; {
		arm := n
		if n.op == types.Oseq {
			arm = n.left
			n = n.right
		} else {
			n = nil
		}

		j := gen.nextinst()
		if arm.left == nil {
			wild = j
		} else {
			pat := arm.left
			for pat != nil {
				q, rest := nextpat(pat)
				pat = rest
				if q.op == types.Oconst || q.op == types.Opat {
					labs[findlab(ctype, q, labs, nlab)].inst = j
				}
				if q.op == types.Opat && q.right != nil && subjbase != nil {
					tagty := q.left.ty
					fd := tagty.ids
					for bn := q.right; bn != nil && fd != nil; bn = bn.right {
						id := bn
						if bn.op == types.Oseq {
							id = bn.left
						}
						boff := mkconst(id.line, id.pos, big(fd.offset))
						boff.ty = tint()
						baddr := types.mkn(types.Oadd, types.dupn(subjbase), boff)
						baddr.line = id.line
						baddr.pos = id.pos
						baddr.ty = tint()
						bind := types.mkn(types.Oind, baddr, nil)
						bind.line = id.line
						bind.pos = id.pos
						bind.ty = fd.ty
						sumark(bind)
						dst := newnode()
						dst.op = types.Oname
						dst.decl = id.decl
						dst.ty = id.decl.ty
						dst.line = id.line
						dst.pos = id.pos
						sumark(dst)
						ecom(id.line, id.pos, dst, bind)
						fd = fd.next
						if bn.op != types.Oseq {
							break
						}
					}
				}
			}
		}

		k := gen.nextinst()
		scom(arm.right)
		sline := lastline()
		spos := lastpos()
		if k == gen.nextinst() {
			sline = arm.line
			spos = arm.pos
		}
		j = gen.genrawop(sline, spos, gen.IJMP, nil, nil, nil)
		j.branch = jmps
		jmps = j
	}
	gen.patch(jmps, gen.nextinst())
	if wild == nil {
		wild = gen.nextinst()
	}
	c.iwild = wild

	for i := 0; i < nlab; i++ {
		if labs[i].inst == nil {
			fatal(sys.sprint("casecom: label %d unset", i))
		}
	}

	if subjbase != nil {
		gen.tfree(tmp)
	}
	d.ty.cse = c
	types.sizetype(d.ty)
	appglobal(d)
}

// a store through a string index, see com.c's indsstore()
func indsstore(line int, pos int, n ref types.Node) {
	tr := newnode()
	tv := newnode()
	tu := newnode()
	left := n.left.left
	right := n.left.right
	fcb := fixcallbase(left)
	fd := fixdblind(left)
	if left.addable >= Rcant {
		fatal("indsstore: string not addressable")
	}
	if right.addable >= Ralways {
		right = ecom(right.line, right.pos, gen.talloc(tr, right.ty, nil), right)
	}
	var v ref types.Node
	match n.op {
	case types.Oas:
		v = n.right
		if v.addable >= Rcant {
			v = ecom(v.line, v.pos, gen.talloc(tv, v.ty, nil), v)
		}
	case types.Oinc, types.Odec:
		u := gen.talloc(tu, tint(), nil)
		gen.genop(line, pos, types.Oinds, left, right, u)
		one := mkconst(line, pos, big(1))
		one.ty = tint()
		sumark(one)
		aop := types.Osub
		if n.op == types.Oinc {
			aop = types.Oadd
		}
		gen.genop(line, pos, aop, one, nil, u)
		v = u
	default:
		v = n.right
		if v.addable >= Rcant {
			v = ecom(v.line, v.pos, gen.talloc(tv, v.ty, nil), v)
		}
		u := gen.talloc(tu, tint(), nil)
		gen.genop(line, pos, types.Oinds, left, right, u)
		gen.genop(line, pos, n.op, v, nil, u)
		v = u
	}
	gen.genrawop(line, pos, gen.IINSC, v, right, left)
	gen.tfree(tr)
	gen.tfree(tv)
	gen.tfree(tu)
	gen.tfree(fd)
	gen.tfree(fcb)
}

// store the zero value of type t into dst
func zerocom(line int, pos int, dst ref types.Node, t ref types.Type) {
	match t.kind {
	case types.Tint, types.Tbyte, types.Tbig:
		z := mkconst(line, pos, big(0))
		z.ty = t
		sumark(z)
		gen.genmove(line, pos, gen.Mas, t, z, dst)
		return
	case types.Treal:
		z := mkrconst(line, pos, 0.0)
		z.ty = types.basic(types.Treal)
		sumark(z)
		gen.genmove(line, pos, gen.Mas, t, z, dst)
		return
	case types.Tadt, types.Tadtpick, types.Ttuple:
		for id := t.ids; id != nil; id = id.next {
			if id.store != types.Dfield {
				continue
			}
			adr := types.mkn(types.Oadr, types.dupn(dst), nil)
			adr.line = line
			adr.pos = pos
			adr.ty = t
			off := mkconst(line, pos, big(id.offset))
			off.ty = tint()
			addr := types.mkn(types.Oadd, adr, off)
			addr.line = line
			addr.pos = pos
			addr.ty = tint()
			ind := types.mkn(types.Oind, addr, nil)
			ind.line = line
			ind.pos = pos
			ind.ty = id.ty
			sumark(ind)
			zerocom(line, pos, ind, id.ty)
		}
		return
	default:
		if types.isptr(t.kind) == 0 {
			return
		}
		z := types.mkn(types.Oname, nil, nil)
		z.line = line
		z.pos = pos
		z.decl = nildecl
		z.ty = t
		nildecl.refs++
		sumark(z)
		gen.genmove(line, pos, gen.Mas, t, z, dst)
		return
	}
}

func assignop(n ref types.Node) {
	gen.pushblock()
	sumark(n.left)
	sumark(n.right)
	if n.left.op == types.Oindx {
		ia := indxaddr(n.line, n.pos, n.left)
		r := n.right
		tr := newnode()
		if r.addable >= Rcant {
			r = ecom(r.line, r.pos, gen.talloc(tr, r.ty, nil), r)
		}
		gen.genop(n.line, n.pos, n.op, r, nil, ia.ind)
		gen.tfree(tr)
		indxaddrfree(ia)
		gen.popblock()
		return
	}
	if n.left.op == types.Oinds {
		indsstore(n.line, n.pos, n)
		gen.popblock()
		return
	}
	fcb := fixcallbase(n.left)
	fd := fixdblind(n.left)
	e := n.left
	if e.addable >= Rcant {
		fatal("scom: assignop lhs not addressable")
	}
	r := n.right
	tr := newnode()
	if r.addable >= Rcant {
		r = ecom(r.line, r.pos, gen.talloc(tr, r.ty, nil), r)
	}
	gen.genop(n.line, n.pos, n.op, r, nil, e)
	gen.tfree(tr)
	gen.tfree(fd)
	gen.tfree(fcb)
	gen.popblock()
}

func incdec(n ref types.Node) {
	gen.pushblock()
	sumark(n.left)
	aop := types.Osub
	if n.op == types.Oinc {
		aop = types.Oadd
	}
	if n.left.op == types.Oindx {
		ia := indxaddr(n.line, n.pos, n.left)
		one := mkconst(n.line, n.pos, big(1))
		one.ty = tint()
		sumark(one)
		gen.genop(n.line, n.pos, aop, one, nil, ia.ind)
		indxaddrfree(ia)
		gen.popblock()
		return
	}
	if n.left.op == types.Oinds {
		indsstore(n.line, n.pos, n)
		gen.popblock()
		return
	}
	fcb := fixcallbase(n.left)
	fd := fixdblind(n.left)
	one := mkconst(n.line, n.pos, big(1))
	one.ty = tint()
	sumark(one)
	gen.genop(n.line, n.pos, aop, one, nil, n.left)
	gen.tfree(fd)
	gen.tfree(fcb)
	gen.popblock()
}

func ascom(n ref types.Node) {
	gen.pushblock()
	if n.left.op == types.Oseq {
		destructure(n.line, n.pos, n.left, n.right)
		gen.popblock()
		return
	}
	sumark(n.right)
	sumark(n.left)
	if n.right.op == types.Oref && n.right.left != nil && n.right.left.op == types.Ocomposite {
		tref := newnode()
		ecom(n.line, n.pos, gen.talloc(tref, n.right.ty, nil), n.right)
		saved := n.right
		n.right = tref
		scom(n)
		n.right = saved
		gen.tfree(tref)
		gen.popblock()
		return
	}
	if n.left.op == types.Oindx {
		ia := indxaddr(n.line, n.pos, n.left)
		ecom(n.line, n.pos, ia.ind, n.right)
		indxaddrfree(ia)
		gen.popblock()
		return
	}
	if n.left.op == types.Oinds {
		indsstore(n.line, n.pos, n)
		gen.popblock()
		return
	}
	fcb := fixcallbase(n.left)
	fd := fixdblind(n.left)
	if n.right.op == types.Ocomposite {
		storecompositezero(n.line, n.pos, n.left, n.right)
	} else {
		ecom(n.line, n.pos, n.left, n.right)
	}
	gen.tfree(fd)
	gen.tfree(fcb)
	gen.popblock()
}

func scom(n ref types.Node) {
	for ; n != nil; n = n.right {
		match n.op {
		case types.Oseq:
			scom(n.left)
			continue
		case types.Oscope:
			scom(n.left)
			return
		case types.Odas:
			gen.pushblock()
			if n.left.op == types.Oseq {
				destructure(n.line, n.pos, n.left, n.right)
				gen.popblock()
				return
			}
			sumark(n.right)
			sumark(n.left)
			if n.right.op == types.Ocomposite {
				if compositexhaustive(n.right) != 0 {
					adr := types.mkn(types.Oadr, types.dupn(n.left), nil)
					adr.line = n.line
					adr.pos = n.pos
					adr.ty = n.left.ty
					storecomposite(n.line, n.pos, adr, n.right)
				} else {
					storecompositezero(n.line, n.pos, n.left, n.right)
				}
			} else {
				ecom(n.line, n.pos, n.left, n.right)
			}
			gen.popblock()
			return
		case types.Oas:
			ascom(n)
			return
		case types.Ovardecl:
			if n.aux == nil {
				for names := n.left; names != nil; names = names.right {
					id := names
					if names.op == types.Oseq {
						id = names.left
					}
					gen.pushblock()
					sumark(id)
					zerocom(id.line, id.pos, id, id.ty)
					gen.popblock()
					if names.op != types.Oseq {
						break
					}
				}
				return
			}
			for names := n.left; names != nil; names = names.right {
				id := names
				if names.op == types.Oseq {
					id = names.left
				}
				gen.pushblock()
				sumark(n.aux)
				sumark(id)
				if n.aux.op == types.Ocomposite {
					adr := types.mkn(types.Oadr, types.dupn(id), nil)
					adr.line = id.line
					adr.pos = id.pos
					adr.ty = id.ty
					storecomposite(id.line, id.pos, adr, n.aux)
				} else {
					ecom(id.line, id.pos, id, n.aux)
				}
				gen.popblock()
				if names.op != types.Oseq {
					break
				}
			}
			return
		case types.Oaddas, types.Osubas, types.Omulas, types.Odivas, types.Omodas, types.Oandas, types.Ooras, types.Oxoras, types.Olshas, types.Orshas:
			assignop(n)
			return
		case types.Oinc, types.Odec:
			incdec(n)
			return
		case types.Oexpr:
			gen.pushblock()
			e := n.left
			sumark(e)
			if e.ty != nil && e.ty != tnone() && e.ty.kind != types.Terror && e.op != types.Ocall {
				tret := newnode()
				ecom(e.line, e.pos, gen.talloc(tret, e.ty, nil), e)
				gen.tfree(tret)
			} else {
				ecom(e.line, e.pos, nil, e)
			}
			gen.popblock()
			return
		case types.Oret:
			gen.pushblock()
			if n.left != nil {
				tret := newnode()
				if n.left.op == types.Ocomposite {
					dst := gen.retalloc(tret, n.left)
					storecomposite(n.line, n.pos, dst.left, n.left)
				} else {
					sumark(n.left)
					ecom(n.line, n.pos, gen.retalloc(tret, n.left), n.left)
				}
			}
			gen.genrawop(n.line, n.pos, gen.IRET, nil, nil, nil)
			gen.popblock()
			return
		case types.Oif:
			gen.pushblock()
			sumark(n.left)
			p := bcom(n.left, 1, nil)
			scom(n.right)
			if n.aux != nil {
				pp := gen.genrawop(lastline(), lastpos(), gen.IJMP, nil, nil, nil)
				gen.patch(p, gen.nextinst())
				scom(n.aux)
				gen.patch(pp, gen.nextinst())
			} else {
				gen.patch(p, gen.nextinst())
			}
			gen.popblock()
			return
		case types.Ofor:
			var init ref types.Node
			var post ref types.Node
			if n.aux != nil {
				init = n.aux.left
				post = n.aux.right
			}
			if init != nil {
				scom(init)
			}
			top := gen.nextinst()
			var p ref types.Inst
			if n.left != nil {
				gen.pushblock()
				sumark(n.left)
				p = bcom(n.left, 1, nil)
				gen.popblock()
			}
			if labdep >= MaxLab {
				fatal("label stack overflow")
			}
			breaks[labdep] = nil
			conts[labdep] = nil
			isloop[labdep] = 1
			labdep++
			scom(n.right)
			labdep--
			gen.patch(conts[labdep], gen.nextinst())
			if post != nil {
				scom(post)
			}
			gen.pushblock()
			gen.patch(gen.genrawop(lastline(), lastpos(), gen.IJMP, nil, nil, nil), top)
			gen.popblock()
			if p != nil {
				gen.patch(p, gen.nextinst())
			}
			gen.patch(breaks[labdep], gen.nextinst())
			return
		case types.Obreak:
			gen.pushblock()
			d := labeldepth(n)
			if d >= 0 {
				bccom(n, 1, d)
			}
			gen.popblock()
			return
		case types.Ocont:
			gen.pushblock()
			d := labeldepth(n)
			if d >= 0 {
				bccom(n, 0, d)
			}
			gen.popblock()
			return
		case types.Olabel:
			if labdep >= MaxLab {
				fatal("label stack overflow")
			}
			labels[labdep] = n.left.sym
			scom(n.right)
			return
		case types.Omatch:
			if n.ty == nil || n.ty.cse == nil {
				error(n.line, "match not typed")
				return
			}
			gen.pushblock()
			if labdep >= MaxLab {
				fatal("label stack overflow")
			}
			breaks[labdep] = nil
			conts[labdep] = nil
			isloop[labdep] = 0
			labdep++
			casecom(n)
			labdep--
			gen.patch(breaks[labdep], gen.nextinst())
			gen.popblock()
			return
		case types.Oalt:
			if n.ty == nil || n.ty.cse == nil {
				error(n.line, "alt not typed")
				return
			}
			gen.pushblock()
			if labdep >= MaxLab {
				fatal("label stack overflow")
			}
			breaks[labdep] = nil
			conts[labdep] = nil
			isloop[labdep] = 0
			labdep++
			altcom(n)
			labdep--
			gen.patch(breaks[labdep], gen.nextinst())
			gen.popblock()
			return
		case types.Otry:
			// try/catch: markers and an exception table entry (com.c)
			gen.pushblock()
			pp := gen.genrawop(n.right.line, n.right.pos, gen.IEXC0, nil, nil, nil)
			p1 := gen.nextinst()
			scom(n.left)
			p2 := gen.nextinst()
			p3 := gen.genrawop(n.right.line, n.right.pos, gen.IJMP, nil, nil, nil)
			p := gen.genrawop(n.right.line, n.right.pos, gen.IEXC, nil, nil, nil)
			c := ref types.Case{nlab: 0, nsnd: 0, offset: 0, labs: nil, wild: nil, iwild: nil, tagof: nil}
			c.iwild = gen.nextinst()
			ct := types.mktype(n.line, n.pos, types.Tcase, nil, nil)
			ct.cse = c
			p.d.decl = types.mkdecl(n.line, n.pos, types.Dtype, ct)
			scom(n.right)
			gen.patch(p3, gen.nextinst())
			excs = ref types.Except{p1: p1, p2: p2, c: c, d: n.aux.decl, next: excs}
			gen.patch(pp, p)
			gen.popblock()
			return
		default:
			gen.pushblock()
			sumark(n)
			ecom(n.line, n.pos, nil, n)
			gen.popblock()
			return
		}
	}
}

func modiface(v ref types.Decl) ref types.Decl {
	m := v.importid
	if m == nil || m.ty == nil {
		return nil
	}
	if m.ty.tof == nil || m.ty.tof.decl == nil {
		error(v.line, sys.sprint("imported module %s has no interface", m.sym))
		return nil
	}
	iface := m.ty.tof.decl
	iface.refs++
	found := 0
	for e := globals; e != nil; e = e.next {
		if e == iface {
			found = 1
			break
		}
	}
	if found == 0 {
		appglobal(iface)
	}
	types.sizetype(iface.ty)
	return iface
}

func autoload(v ref types.Decl) {
	m := v.importid
	if m == nil || m.ty == nil {
		return
	}
	id := m.ty.ids
	for id != nil {
		if id.store == types.Dconst && id.sym != nil && id.sym == "PATH" {
			break
		}
		id = id.next
	}
	if id == nil || id.init == nil {
		error(v.line, sys.sprint("imported module %s has no PATH", m.sym))
		return
	}
	iface := modiface(v)
	if iface == nil {
		return
	}

	pn := mksconst(v.line, v.pos, id.init.sym)
	pn.ty = tstring()
	sumark(pn)

	modn := newnode()
	modn.op = types.Oname
	modn.decl = v
	modn.ty = v.ty
	modn.addable = Rmreg
	modn.line = v.line
	modn.pos = v.pos

	ifn := newnode()
	ifn.op = types.Oname
	ifn.decl = iface
	ifn.ty = iface.ty
	ifn.addable = Rldt
	ifn.line = v.line
	ifn.pos = v.pos

	gen.genrawop(v.line, v.pos, gen.ILOAD, pn, ifn, modn)
}

func needmodinit() int {
	for l := check.importlist(); l != nil; l = tl(l) {
		if hd(l).refs > 0 {
			return 1
		}
	}
	for d := check.moduledecllist(); d != nil; d = d.link {
		if d.runinit != 0 {
			return 1
		}
	}
	return 0
}

func fncom(decl ref types.Decl) {
	curfn = decl
	decl.pc = gen.nextinst()
	gen.tinit()
	labdep = 0

	body := decl.init.aux
	line := body.line
	pos := body.pos

	var guard ref types.Inst
	if needmodinit() != 0 {
		if loadedflag == nil {
			loadedflag = types.mkdecl(line, pos, types.Dglobal, tint())
			loadedflag.sym = ".loaded"
			loadedflag.dot = impdecl
			appglobal(loadedflag)
		}
		flagn := newnode()
		flagn.op = types.Oname
		flagn.decl = loadedflag
		flagn.ty = tint()
		flagn.addable = Rmreg
		flagn.line = line
		flagn.pos = pos
		zero := newnode()
		zero.op = types.Oconst
		zero.ty = tint()
		zero.addable = Rconst
		zero.val = big(0)
		zero.line = line
		zero.pos = pos
		one := types.dupn(zero)
		one.val = big(1)
		gen.pushblock()
		guard = gen.genbra(line, pos, types.Oneq, flagn, zero)
		gen.genmove(line, pos, gen.Mas, tint(), one, flagn)
		for l := check.importlist(); l != nil; l = tl(l) {
			if hd(l).refs > 0 {
				autoload(hd(l))
			}
		}
		gen.popblock()
	}

	if guard != nil {
		for d := check.moduledecllist(); d != nil; d = d.link {
			if d.runinit == 0 {
				continue
			}
			gen.pushblock()
			g := types.mkn(types.Oname, nil, nil)
			g.line = d.init.line
			g.pos = d.init.pos
			g.decl = d
			g.ty = d.ty
			sumark(g)
			if d.init.op == types.Ocomposite {
				adr := types.mkn(types.Oadr, types.dupn(g), nil)
				adr.line = g.line
				adr.pos = g.pos
				adr.ty = g.ty
				storecomposite(g.line, g.pos, adr, d.init)
			} else {
				sumark(d.init)
				ecom(g.line, g.pos, g, d.init)
			}
			gen.popblock()
		}
		gen.patch(guard, gen.nextinst())
	}

	scom(body)

	gen.pushblock()
	gen.genrawop(line, pos, gen.IRET, nil, nil, nil)
	gen.popblock()

	gen.reach(decl.pc)

	var loc ref types.Decl
	var last ref types.Decl
	for d := decl.locals; d != nil; {
		nx := d.link
		d.link = nil
		d.next = nil
		if loc == nil {
			loc = d
		} else {
			last.next = d
		}
		last = d
		d = nx
	}
	loc = types.appdecls(loc, gen.tdecls())
	decl.offset = types.idoffsets(loc, decl.offset, types.MaxAlign)
	last = decl.ty.ids
	for last != nil && last.next != nil {
		last = last.next
	}
	if last != nil {
		last.next = loc
	} else {
		decl.ty.ids = loc
	}

	decl.desc = types.gendesc(decl, decl.offset, decl.ty.ids)
	decl.locals = loc
	if decl.offset > gen.maxstack() {
		gen.setmaxstack(decl.offset)
	}

	if loc != nil {
		last = decl.ty.ids
		for last != nil && last.next != loc {
			last = last.next
		}
		if last != nil && last.next == loc {
			last.next = nil
		} else if decl.ty.ids == loc {
			decl.ty.ids = nil
		}
	}
	curfn = nil
}

func modfix(m ref types.Decl) int {
	if m == nil || m.ty == nil || m.ty.tof == nil {
		return 0
	}
	offset := 0
	for id := m.ty.tof.ids; id != nil; id = id.next {
		id.offset = offset
		offset++
	}
	if m.ty.tof.decl != nil && m.ty.tof.decl.init != nil {
		m.ty.tof.decl.init.val = big(offset)
	}

	for id := m.ty.ids; id != nil; id = id.next {
		if id.store == types.Dfn && id.iface != nil {
			id.iface.pc = id.pc
			id.iface.desc = id.desc
		}
	}
	for id := m.ty.tof.ids; id != nil; id = id.next {
		if id.store == types.Dfn {
			if id.pc == nil && id.iface != nil {
				id.pc = id.iface.pc
			}
			if id.desc == nil && id.iface != nil {
				id.desc = id.iface.desc
			}
		}
	}
	if m.ty.tof.decl != nil && m.ty.tof.decl.init != nil {
		return int(m.ty.tof.decl.init.val)
	}
	return offset
}

func modcom(file string, out string) int {
	infile = file
	nerrors = 0
	loadedflag = nil
	excs = nil
	impdecl = check.moduledecl()
	nildecl = check.nildeclare()
	if impdecl == nil {
		return nerrors
	}

	bcinit()
	globals = nil
	nlabel = 0
	gen.setmaxstack(types.MaxTemp)
	gen.genstart()

	for l := check.importlist(); l != nil; l = tl(l) {
		d := hd(l)
		if d.refs <= 0 {
			continue
		}
		d.next = nil
		appglobal(d)
	}
	if nildecl.refs > 0 {
		nildecl.next = nil
		appglobal(nildecl)
	}
	for d := check.moduledecllist(); d != nil; d = d.link {
		d.next = nil
		appglobal(d)
	}

	fns := check.fnlist()
	nfns := check.nfnlist()
	for i := 0; i < nfns; i++ {
		fncom(fns[i])
	}

	if gen.blocks() != -1 {
		fatal("blocks not nested correctly")
	}
	gen.setfirstinst(gen.firstinst().next)
	if nerrors != 0 {
		return nerrors
	}

	// zerocom() references nildecl during fncom, after the globals
	// list was built: give it a slot now if it has none (com.c)
	if nildecl.refs > 0 {
		e := globals
		for e != nil && e != nildecl {
			e = e.next
		}
		if e == nil {
			nildecl.next = nil
			appglobal(nildecl)
		}
	}

	types.narrowmods()

	for l := check.importlist(); l != nil; l = tl(l) {
		if hd(l).importid != nil {
			modfix(hd(l).importid)
		}
	}
	nlink := modfix(impdecl)

	// the exported variables first, in the .mp record's order, so
	// idoffsets() gives them the record's offsets (com.c)
	if impdecl.ty.tof != nil && impdecl.ty.tof.ids != nil && impdecl.ty.tof.ids.store == types.Dglobal {
		mp := impdecl.ty.tof.ids
		types.sizetype(mp.ty)
		var ex ref types.Decl
		var exlast ref types.Decl
		for c := mp.ty.ids; c != nil; c = c.next {
			var prev ref types.Decl
			e := globals
			for e != nil && e != c.iface {
				prev = e
				e = e.next
			}
			if e == nil {
				fatal(sys.sprint("exported variable %s is not a global", c.sym))
			}
			if prev == nil {
				globals = e.next
			} else {
				prev.next = e.next
			}
			e.next = nil
			if ex == nil {
				ex = e
			} else {
				exlast.next = e
			}
			exlast = e
		}
		if ex != nil {
			exlast.next = globals
			globals = ex
		}
	}

	g, ldts := gen.resolveldts(globals)
	globals = g
	offset := types.idoffsets(g, 0, types.IBY2WD)
	ldtoff := types.idindices(ldts)
	ndesc := gen.resolvedesc(impdecl, offset, g)
	ninst := gen.resolvepcs(gen.firstinst())

	maxstack := gen.maxstack() * 10

	// handlers were pushed as met: the table lists them in order
	var rev ref types.Except
	for e := excs; e != nil; {
		next := e.next
		e.next = rev
		rev = e
		e = next
	}
	excs = rev

	hints := 0
	if ldts != nil {
		hints |= HASLDT
	}
	if excs != nil {
		hints |= HASEXCEPT
	}

	if disw.open(out) == 0 {
		sys.fprint(sys.fildes(2), "ember: can't write %s: %r\n", out)
		nerrors++
		return nerrors
	}
	disw.discon(XMAGIC)
	disw.discon(hints)
	disw.discon(maxstack)
	disw.discon(ninst)
	disw.discon(offset)
	disw.discon(ndesc)
	disw.discon(nlink)
	disw.disentry(check.entry())
	disw.disinst(gen.firstinst())
	disw.disdesc(types.descriptorlist())
	disw.disvar(offset, g)
	disw.dismod(impdecl)
	if ldts != nil {
		disw.disldt(ldtoff, ldts)
	}
	if excs != nil {
		// the writer's generator instance has no instruction list:
		// resolve the ranges' pcs here
		for e := excs; e != nil; e = e.next {
			if e.p1.reach != 0 || e.p2.reach != 0 {
				e.pc1 = gen.getpc(e.p1)
				e.pc2 = gen.getpc(e.p2)
			}
		}
		disw.disexc(excs)
	}
	disw.dispath(file)
	disw.close()

	gen.setfirstinst(nil)
	gen.setlastinst(nil)
	types.setdescriptorlist(nil)
	return nerrors
}
