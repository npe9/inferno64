module Types

import sys "sys"
import keyring "keyring"

// a port of ember/types.c; see types.ei.  the C compiler's Src is a
// (line, pos) pair here; its Sym* strings are plain strings; its
// static tables are arrays built once; the symbol-table entries the
// C code pools by name (".m.Mod", "_mktdesc_") live in a small list.

const IBY2WD = 8
const IBY2LG = 8
const MaxTemp = 64
const MaxAlign = 8

const NREAL = 1
const NSTR = 2
const NVARARG = 4
const NCHECKED = 8
const NSPREAD = 16

const Onone = 0
const Omodule = 1
const Oimport = 2
const Otypedecl = 3
const Ovardecl = 4
const Ocondecl = 5
const Ofndecl = 6
const Omethod = 7
const Ofield = 8
const Otag = 9
const Otarray = 10
const Otchan = 11
const Otlist = 12
const Otref = 13
const Otfunc = 14
const Ottuple = 15
const Otinst = 16
const Otstruct = 17
const Otpick = 18
const Oscope = 19
const Oseq = 20
const Oif = 21
const Ofor = 22
const Oforctl = 23
const Omatch = 24
const Oalt = 25
const Ocase = 26
const Opat = 27
const Obreak = 28
const Ocont = 29
const Oret = 30
const Ospawn = 31
const Osnd = 32
const Odas = 33
const Oas = 34
const Oaddas = 35
const Osubas = 36
const Omulas = 37
const Odivas = 38
const Omodas = 39
const Oandas = 40
const Ooras = 41
const Oxoras = 42
const Olshas = 43
const Orshas = 44
const Oinc = 45
const Odec = 46
const Oexpr = 47
const Olabel = 48
const Oraise = 49
const Oname = 50
const Oconst = 51
const Onil = 52
const Odot = 53
const Omdot = 54
const Ocall = 55
const Oindex = 56
const Oinds = 57
const Oindx = 58
const Oslice = 59
const Ocomposite = 60
const Oelem = 61
const Ofunclit = 62
const Otuple = 63
const Ochk = 64
const Orcv = 65
const Oref = 66
const Oload = 67
const Olen = 68
const Ohd = 69
const Otl = 70
const Ocons = 71
const Ocast = 72
const Oneg = 73
const Onot = 74
const Oinv = 75
const Oadd = 76
const Osub = 77
const Omul = 78
const Odiv = 79
const Omod = 80
const Oand = 81
const Oor = 82
const Oxor = 83
const Olsh = 84
const Orsh = 85
const Oandand = 86
const Ooror = 87
const Oeq = 88
const Oneq = 89
const Olt = 90
const Ogt = 91
const Oleq = 92
const Ogeq = 93
const Oind = 94
const Oadr = 95
const Oused = 96
const Onothing = 97
const Ochan = 98
const Oarray = 99
const Oend = 100

const Tnone = 0
const Tadt = 1
const Tadtpick = 2
const Tarray = 3
const Tbig = 4
const Tbyte = 5
const Tchan = 6
const Treal = 7
const Tfn = 8
const Tint = 9
const Tlist = 10
const Tmodule = 11
const Tref = 12
const Tstring = 13
const Ttuple = 14
const Texception = 15
const Tfix = 16
const Tpoly = 17
const Tainit = 18
const Talt = 19
const Tany = 20
const Tarrow = 21
const Tcase = 22
const Tcasel = 23
const Tcasec = 24
const Tdot = 25
const Terror = 26
const Tgoto = 27
const Tid = 28
const Tiface = 29
const Texcept = 30
const Tinst = 31
const Tend = 32

const Dtype = 0
const Dfn = 1
const Dglobal = 2
const Darg = 3
const Dlocal = 4
const Dconst = 5
const Dfield = 6
const Dtag = 7
const Dimport = 8
const Dunbound = 9
const Dundef = 10
const Dwundef = 11
const Dend = 12

const OKbind = 1
const OKverify = 2
const OKsized = 4
const OKref = 8
const OKclass = 16
const OKcyc = 32
const OKcycsize = 64
const OKmodref = 128
const OKmask = 255
const TReq = 1

// Dis conversion opcodes (include/isa.h), for castop()
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
const ICVTLF = 135
const ICVTFL = 136
const ICVTLW = 137
const ICVTWL = 138
const ICVTLC = 139
const ICVTCL = 140

type Node struct {
	op int
	left ref Node
	right ref Node
	aux ref Node
	sym string
	val big
	rval real
	flags int
	line int
	pos int
	ty ref Type
	decl ref Decl
	addable int
	temps int
}

type Type struct {
	kind int
	varargs int
	hasenv int
	ok int
	linkall int
	rec int
	align int
	sig int
	size int
	decl ref Decl
	tof ref Type
	ids ref Decl
	tags ref Decl
	meths ref Decl
	cse ref Case
	teq ref Type
	eq ref Teq
	tparams ref Node
	tbody ref Node
	tinsts ref Ginst
	methtmpl ref Decl
	gtemplate ref Type
	ginst ref Ginst
	line int
	pos int
}

type Decl struct {
	sym string
	store int
	nid int
	das int
	dot ref Decl
	ty ref Type
	refs int
	offset int
	tag int
	scope int
	next ref Decl
	old ref Decl
	importid ref Decl
	init ref Node
	runinit int
	tref int
	cycle int
	cyc int
	implicit int
	inl int
	iface ref Decl
	locals ref Decl
	link ref Decl
	pc ref Inst
	desc ref Desc
	valty ref Type
	wrapdecl ref Decl
	tparams ref Node
	finsts ref Ginst
	checked int
	enclosing ref Decl
	captures list ref Decl
	capuses []ref Node
	ncapuses int
	capty ref Type
	line int
	pos int
}

// an operand address and a Dis instruction (gen.e builds them, disw.e
// encodes them); here so a Decl can point at its first instruction
type Addr struct {
	reg int
	offset int
	decl ref Decl
}

type Inst struct {
	line int
	pos int
	op int
	pc int
	reach int
	sm int
	mm int
	dm int
	s Addr
	m Addr
	d Addr
	branch ref Inst
	next ref Inst
	block int
}

type Desc struct {
	id int
	used int
	map []byte
	size int
	nmap int
	next ref Desc
}

type Ginst struct {
	nargs int
	args []ref Type
	ty ref Type
	decl ref Decl
	next ref Ginst
}

type Teq struct {
	id int
	ty ref Type
	eq ref Teq
}

type Label struct {
	node ref Node
	isptr int
	start ref Node
	stop ref Node
	inst ref Inst
}

type Case struct {
	nlab int
	nsnd int
	offset int
	labs []ref Label
	wild ref Node
	iwild ref Inst
	tagof ref Type
}

var opnames = [101]string{"none", "module", "import", "typedecl", "vardecl", "condecl", "fndecl", "method", "field", "tag", "tarray", "tchan", "tlist", "tref", "tfunc", "ttuple", "tinst", "tstruct", "tpick", "scope", "seq", "if", "for", "forctl", "match", "alt", "case", "pat", "break", "continue", "return", "spawn", "send", "das", "as", "addas", "subas", "mulas", "divas", "modas", "andas", "oras", "xoras", "lshas", "rshas", "inc", "dec", "expr", "label", "raise", "name", "const", "nil", "dot", "mdot", "call", "index", "inds", "indx", "slice", "composite", "elem", "funclit", "tuple", "chk", "rcv", "ref", "load", "len", "hd", "tl", "cons", "cast", "neg", "not", "inv", "add", "sub", "mul", "div", "mod", "and", "or", "xor", "lsh", "rsh", "andand", "oror", "eq", "neq", "lt", "gt", "leq", "geq", "ind", "adr", "used", "nothing", "chan", "array", "end"}

var kindnames = [33]string{"no type", "adt", "adt", "array", "big", "byte", "chan", "real", "fn", "int", "list", "module", "ref", "string", "tuple", "exception", "fixed point", "polymorphic", "array initializers", "alt channels", "polymorphic type", "->", "case int labels", "case big labels", "case string labels", ".", "type error", "goto labels", "id", "module interface", "exception handler table", "instantiated type", "end"}

// tattr: isptr, refable, conable, big, vis -- one array per column
var attrptr = [33]int{0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
var attrbig = [33]int{0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1, 1, 1, 0}

var storenames = [13]string{"type", "function", "global", "argument", "local", "con", "field", "pick tag", "import", "unbound", "undefined", "undefined", "end"}
var storespaces = [13]int{0, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0}

var sigkinds = [33]int{'n', 'a', 'p', 'A', 'B', 'b', 'C', 'r', 'f', 'i', 'L', 'm', 'R', 's', 't', 'e', 'x', 'P', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

const SIGSELF = 'S'
const SIGVARARGS = '*'
const SIGCYC = 'y'
const SIGREC = '@'

var tbig ref Type
var tbyte ref Type
var tint ref Type
var treal ref Type
var tstring ref Type
var tany ref Type
var tnone ref Type
var terror ref Type
var tunknown ref Type
var tfnptr ref Type
var descriptors ref Desc

var eqclass = [33]ref Teq
var eqrec = 0
var eqset = 0

type Symd struct {
	name string
	d ref Decl
}

var symdecls list ref Symd

func symdecl(name string) ref Decl {
	for l := symdecls; l != nil; l = tl(l) {
		if hd(l).name == name {
			return hd(l).d
		}
	}
	return nil
}

func setsymdecl(name string, d ref Decl) {
	for l := symdecls; l != nil; l = tl(l) {
		if hd(l).name == name {
			hd(l).d = d
			return
		}
	}
	symdecls = ref Symd{name: name, d: d} :: symdecls
}

func opname(op int) string {
	if op < 0 || op >= len(opnames) {
		return sys.sprint("op%d", op)
	}
	return opnames[op]
}

func kindname(k int) string {
	return kindnames[k]
}

func storename(s int) string {
	return storenames[s]
}

func storespace(s int) int {
	return storespaces[s]
}

func isptr(k int) int {
	return attrptr[k]
}

func isbig(k int) int {
	return attrbig[k]
}

func basic(kind int) ref Type {
	match kind {
	case Tbig:
		return tbig
	case Tbyte:
		return tbyte
	case Tint:
		return tint
	case Treal:
		return treal
	case Tstring:
		return tstring
	case Tany:
		return tany
	case Tnone:
		return tnone
	case Terror:
		return terror
	}
	return nil
}

func tunknownt() ref Type {
	return tunknown
}

func tfnptrt() ref Type {
	return tfnptr
}

func descriptorlist() ref Desc {
	return descriptors
}

func setdescriptorlist(d ref Desc) {
	descriptors = d
}

func mkbasic(kind int, size int, al int) ref Type {
	t := mktype(0, 0, kind, nil, nil)
	t.size = size
	t.align = al
	t.ok = OKmask
	return t
}

func typeinit() {
	tbig = mkbasic(Tbig, IBY2LG, IBY2LG)
	tbyte = mkbasic(Tbyte, 1, 1)
	tint = mkbasic(Tint, IBY2WD, IBY2WD)
	treal = mkbasic(Treal, IBY2LG, IBY2LG)
	tstring = mkbasic(Tstring, IBY2WD, IBY2WD)
	tany = mkbasic(Tany, IBY2WD, IBY2WD)
	tnone = mkbasic(Tnone, 0, 1)
	terror = mkbasic(Terror, 0, 1)
	tunknown = mkbasic(Terror, 0, 1)
	tfnptr = mktype(0, 0, Ttuple, nil, nil)
	id0 := mkdecl(0, 0, Dfield, tany)
	id0.sym = "t0"
	id1 := mkdecl(0, 0, Dfield, tint)
	id1.sym = "t1"
	id2 := mkdecl(0, 0, Dfield, tany)
	id2.sym = "t2"
	id0.next = id1
	id1.next = id2
	tfnptr.ids = id0
	sizetype(tfnptr)
	descriptors = nil
	for i := 0; i < len(eqclass); i++ {
		eqclass[i] = nil
	}
	symdecls = nil
}

func mktype(line int, pos int, kind int, tof ref Type, ids ref Decl) ref Type {
	return ref Type{kind: kind, tof: tof, ids: ids, line: line, pos: pos, varargs: 0, hasenv: 0, ok: 0, linkall: 0, rec: 0, align: 0, sig: 0, size: 0, decl: nil, tags: nil, meths: nil, cse: nil, teq: nil, eq: nil, tparams: nil, tbody: nil, tinsts: nil, methtmpl: nil, gtemplate: nil, ginst: nil}
}

// dst takes src's every field (C's *dst = *src)
func copytype(dst ref Type, src ref Type) {
	dst.kind = src.kind
	dst.varargs = src.varargs
	dst.hasenv = src.hasenv
	dst.ok = src.ok
	dst.linkall = src.linkall
	dst.rec = src.rec
	dst.align = src.align
	dst.sig = src.sig
	dst.size = src.size
	dst.decl = src.decl
	dst.tof = src.tof
	dst.ids = src.ids
	dst.tags = src.tags
	dst.meths = src.meths
	dst.cse = src.cse
	dst.teq = src.teq
	dst.eq = src.eq
	dst.tparams = src.tparams
	dst.tbody = src.tbody
	dst.tinsts = src.tinsts
	dst.methtmpl = src.methtmpl
	dst.gtemplate = src.gtemplate
	dst.ginst = src.ginst
	dst.line = src.line
	dst.pos = src.pos
}

// the closure-value shape of a function type: an env parameter
// prepended (check.c's envfn(), shared with iface.e)
func envfn(line int, pos int, pub ref Type) ref Type {
	ids := mkdecl(line, pos, Darg, basic(Tany))
	ids.sym = ".env"
	last := ids
	for p := pub.ids; p != nil; p = p.next {
		np := dupdecl(p)
		np.next = nil
		last.next = np
		last = np
	}
	ft := mktype(line, pos, Tfn, pub.tof, ids)
	ft.varargs = pub.varargs
	ft.hasenv = 1
	ft.ok |= OKverify
	sizetype(ft)
	for p := ft.ids; p != nil; p = p.next {
		sizetype(p.ty)
	}
	sizetype(ft.tof)
	idoffsets(ft.ids, MaxTemp, IBY2WD)
	return ft
}

func mktalt(c ref Case) ref Type {
	t := mktype(0, 0, Talt, nil, nil)
	t.cse = c
	sizetype(t)
	t.ok = OKmask
	return t
}

func mkdecl(line int, pos int, store int, t ref Type) ref Decl {
	d := ref Decl{store: store, ty: t, line: line, pos: pos, nid: 1}
	return d
}

func dupdecl(old ref Decl) ref Decl {
	d := ref Decl{sym: old.sym, store: old.store, nid: old.nid, das: old.das, dot: old.dot, ty: old.ty, refs: old.refs, offset: old.offset, tag: old.tag, scope: old.scope, next: nil, old: old.old, importid: old.importid, init: old.init, runinit: old.runinit, tref: old.tref, cycle: old.cycle, cyc: old.cyc, implicit: old.implicit, iface: old.iface, locals: old.locals, link: old.link, pc: old.pc, desc: old.desc, valty: old.valty, wrapdecl: old.wrapdecl, tparams: old.tparams, finsts: old.finsts, checked: old.checked, enclosing: old.enclosing, captures: old.captures, capuses: old.capuses, ncapuses: old.ncapuses, capty: old.capty, line: old.line, pos: old.pos}
	return d
}

func appdecls(d ref Decl, dd ref Decl) ref Decl {
	if d == nil {
		return dd
	}
	t := d
	for t.next != nil {
		t = t.next
	}
	t.next = dd
	return d
}

func revids(id ref Decl) ref Decl {
	var d ref Decl
	for id != nil {
		next := id.next
		id.next = d
		d = id
		id = next
	}
	return d
}

func namemerge(e ref Decl, f ref Decl) ref Decl {
	rock := ref Decl{}
	d := rock
	for e != nil && f != nil {
		if e.sym <= f.sym {
			d.next = e
			e = e.next
		} else {
			d.next = f
			f = f.next
		}
		d = d.next
	}
	if e != nil {
		d.next = e
	} else {
		d.next = f
	}
	return rock.next
}

func recnamesort(d ref Decl, n int) ref Decl {
	if n <= 1 {
		return d
	}
	m := n / 2 - 1
	dd := d
	for i := 0; i < m; i++ {
		dd = dd.next
	}
	r := dd.next
	dd.next = nil
	return namemerge(recnamesort(d, n / 2), recnamesort(r, (n + 1) / 2))
}

func namesort(d ref Decl) ref Decl {
	n := 0
	for dd := d; dd != nil; dd = dd.next {
		n++
	}
	return recnamesort(d, n)
}

func align(off int, a int) int {
	if a == 0 {
		sys.fprint(sys.fildes(2), "fatal: align 0\n")
		return off
	}
	for off % a != 0 {
		off++
	}
	return off
}

func idoffsets(id ref Decl, offset int, al int) int {
	for ; id != nil; id = id.next {
		if storespace(id.store) != 0 {
			if id.store == Dlocal && id.link != nil {
				id.offset = id.link.offset
				continue
			}
			a := id.ty.align
			if a == 0 {
				a = 1
			}
			offset = align(offset, a)
			id.offset = offset
			offset += id.ty.size
		}
	}
	return align(offset, al)
}

func idindices(id ref Decl) int {
	i := 0
	for ; id != nil; id = id.next {
		if storespace(id.store) != 0 {
			id.offset = i
			i++
		}
	}
	return i
}

func sizetype(t ref Type) {
	if t == nil {
		return
	}
	if (t.ok & OKsized) == OKsized {
		return
	}
	t.ok |= OKsized
	match t.kind {
	case Terror, Tnone, Tbyte, Tint, Tbig, Tstring, Tany, Treal:
		sys.fprint(sys.fildes(2), "fatal: %s should have a size\n", tprint(t))
	case Tref, Tchan, Tarray, Tlist:
		sizetype(t.tof)
		t.size = IBY2WD
		t.align = IBY2WD
	case Tmodule, Tfix, Tpoly:
		t.size = IBY2WD
		t.align = IBY2WD
	case Ttuple, Tadt, Texception:
		if t.tags == nil {
			sz, al := sizeids(t.ids, 0)
			t.size = align(sz, al)
			t.align = al
			return
		}
		sz, al := sizeids(t.ids, IBY2WD)
		if al < IBY2WD {
			al = IBY2WD
		}
		for tg := t.tags; tg != nil; tg = tg.next {
			if (tg.ty.ok & OKsized) == OKsized {
				continue
			}
			tg.ty.ok |= OKsized
			tsz, ta := sizeids(tg.ty.ids, sz)
			a := ta
			if a < al {
				a = al
			}
			tg.ty.size = align(tsz, a)
			tg.ty.align = a
		}
	case Tfn, Tainit:
		t.size = 0
		t.align = 1
	case Talt:
		t.size = t.cse.nlab * 2 * IBY2WD + 2 * IBY2WD
		t.align = IBY2WD
	case Tcase, Tcasec:
		t.size = t.cse.nlab * 3 * IBY2WD + 2 * IBY2WD
		t.align = IBY2WD
	case Tcasel:
		t.size = t.cse.nlab * 6 * IBY2WD + 3 * IBY2WD
		t.align = IBY2LG
	case Tgoto:
		t.size = t.cse.nlab * IBY2WD + IBY2WD
		if t.cse.iwild != nil {
			t.size += IBY2WD
		}
		t.align = IBY2WD
	case Tiface:
		sz := IBY2WD
		for id := t.ids; id != nil; id = id.next {
			sz = align(sz, IBY2WD) + IBY2WD
			sz += len([]byte(id.sym)) + 1
			if id.dot.ty.kind == Tadt {
				sz += len([]byte(id.dot.sym)) + 1
			}
		}
		t.size = sz
		t.align = IBY2WD
	case Texcept:
		t.size = 0
		t.align = IBY2WD
	default:
		sys.fprint(sys.fildes(2), "fatal: sizetype: unknown type kind %d\n", t.kind)
	}
}

func sizeids(id ref Decl, off int) (int, int) {
	al := 1
	for ; id != nil; id = id.next {
		if storespace(id.store) != 0 {
			sizetype(id.ty)
			a := id.ty.align
			if a == 0 {
				a = 1
			}
			if a > al {
				al = a
			}
			off = align(off, a)
			id.offset = off
			off += id.ty.size
		}
	}
	return off, al
}

func gendesc(d ref Decl, size int, decls ref Decl) ref Desc {
	return usedesc(mkdesc(size, decls))
}

func mkdesc(size int, d ref Decl) ref Desc {
	l := (size + 8 * IBY2WD - 1) / (8 * IBY2WD)
	pmap := [l]byte
	n := descmap(d, pmap, 0)
	if n >= 0 {
		n = n / (8 * IBY2WD) + 1
	} else {
		n = 0
	}
	if n > l {
		sys.fprint(sys.fildes(2), "fatal: wrote off end of decl map: %d %d\n", n, l)
	}
	return enterdesc(pmap, size, n)
}

func mktdesc(t ref Type) ref Desc {
	if t.decl == nil {
		t.decl = mkdecl(t.line, t.pos, Dtype, t)
		t.decl.sym = "_mktdesc_"
	}
	if t.decl.desc != nil {
		return t.decl.desc
	}
	l := (t.size + 8 * IBY2WD - 1) / (8 * IBY2WD)
	pmap := [l]byte
	n := tdescmap(t, pmap, 0)
	if n >= 0 {
		n = n / (8 * IBY2WD) + 1
	} else {
		n = 0
	}
	if n > l {
		sys.fprint(sys.fildes(2), "fatal: wrote off end of type map for %s: %d %d\n", tprint(t), n, l)
	}
	d := enterdesc(pmap, t.size, n)
	t.decl.desc = d
	return d
}

func mapcmp(a []byte, b []byte, n int) int {
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			if int(a[i]) < int(b[i]) {
				return -1
			}
			return 1
		}
	}
	return 0
}

func enterdesc(map []byte, size int, nmap int) ref Desc {
	var last ref Desc
	d := descriptors
	for ; d != nil; d = d.next {
		if d.size > size || (d.size == size && d.nmap > nmap) {
			break
		}
		if d.size == size && d.nmap == nmap {
			c := mapcmp(d.map, map, nmap)
			if c == 0 {
				return d
			}
			if c > 0 {
				break
			}
		}
		last = d
	}
	d = ref Desc{id: -1, used: 0, map: map, size: size, nmap: nmap, next: nil}
	if last == nil {
		d.next = descriptors
		descriptors = d
	} else {
		d.next = last.next
		last.next = d
	}
	return d
}

func usedesc(d ref Desc) ref Desc {
	d.used = 1
	return d
}

func descmap(decls ref Decl, map []byte, start int) int {
	last := -1
	for d := decls; d != nil; d = d.next {
		if (d.store == Dtype && d.ty.kind == Tmodule) || d.store == Dfn || d.store == Dconst {
			continue
		}
		if d.store == Dlocal && d.link != nil {
			continue
		}
		m := tdescmap(d.ty, map, d.offset + start)
		if m >= 0 {
			last = m
		}
	}
	return last
}

func setbit(map []byte, offset int) {
	bit := offset / IBY2WD % 8
	map[offset / (8 * IBY2WD)] |= byte(1 << (7 - bit))
}

func tdescmap(t ref Type, map []byte, offset int) int {
	if t == nil {
		return -1
	}
	m := -1
	if t.kind == Talt {
		labs := t.cse.labs
		e := t.cse.nlab
		offset += IBY2WD * 2
		for i := 0; i < e; i++ {
			if labs[i].isptr != 0 {
				setbit(map, offset)
				m = offset
			}
			offset += 2 * IBY2WD
		}
		return m
	}
	if t.kind == Tcasec {
		e := t.cse.nlab
		offset += IBY2WD
		for i := 0; i < e; i++ {
			setbit(map, offset)
			offset += IBY2WD
			setbit(map, offset)
			m = offset
			offset += 2 * IBY2WD
		}
		return m
	}
	if isptr(t.kind) != 0 {
		setbit(map, offset)
		return offset
	}
	if t.kind == Tadtpick {
		if t.rec != 0 || t.tof.rec != 0 {
			sys.fprint(sys.fildes(2), "fatal: illegal cyclic type %s in tdescmap\n", tprint(t))
			return -1
		}
		t.rec = 1
		t.tof.rec = 1
		m1 := descmap(t.ids, map, offset)
		m2 := descmap(t.tof.ids, map, offset)
		t.rec = 0
		t.tof.rec = 0
		if m1 > m2 {
			return m1
		}
		return m2
	}
	if t.kind == Ttuple || t.kind == Tadt || t.kind == Texception {
		if t.rec != 0 {
			sys.fprint(sys.fildes(2), "fatal: illegal cyclic type %s in tdescmap\n", tprint(t))
			return -1
		}
		t.rec = 1
		offset = descmap(t.ids, map, offset)
		t.rec = 0
		return offset
	}
	return -1
}

func modclass() ref Teq {
	return eqclass[Tmodule]
}

func castop(from ref Type, to ref Type) int {
	match from.kind {
	case Tint:
		match to.kind {
		case Tbyte:
			return ICVTWB
		case Treal:
			return ICVTWF
		case Tstring:
			return ICVTWC
		case Tbig:
			return ICVTWL
		}
	case Tbyte:
		if to.kind == Tint {
			return ICVTBW
		}
	case Treal:
		match to.kind {
		case Tint:
			return ICVTFW
		case Tbig:
			return ICVTFL
		case Tstring:
			return ICVTFC
		}
	case Tbig:
		match to.kind {
		case Tint:
			return ICVTLW
		case Treal:
			return ICVTLF
		case Tstring:
			return ICVTLC
		}
	case Tstring:
		match to.kind {
		case Tint:
			return ICVTCW
		case Tbig:
			return ICVTCL
		case Treal:
			return ICVTCF
		case Tarray:
			if to.tof == tbyte {
				return ICVTCA
			}
			return 0
		}
	case Tarray:
		if to.kind == Tstring && from.tof == tbyte {
			return ICVTAC
		}
	}
	return 0
}

func castvia(from ref Type, to ref Type) ref Type {
	if from.kind == Tbyte && (to.kind == Tstring || to.kind == Treal || to.kind == Tbig) {
		return tint
	}
	if to.kind == Tbyte && (from.kind == Tstring || from.kind == Treal || from.kind == Tbig) {
		return tint
	}
	return nil
}

func castable(from ref Type, to ref Type) int {
	if from == nil || to == nil {
		return 0
	}
	if tequal(from, to) != 0 {
		return 1
	}
	if castop(from, to) != 0 {
		return 1
	}
	via := castvia(from, to)
	return via != nil && castop(from, via) != 0 && castop(via, to) != 0
}

func modrefable(t ref Type) {
	if t == nil || (t.ok & OKmodref) == OKmodref {
		return
	}
	t.ok |= OKmodref
	match t.kind {
	case Tchan, Tref, Tarray, Tlist:
		modrefable(t.tof)
	case Tmodule:
		if t.tof != nil {
			t.tof.linkall = 1
		}
		if t.decl != nil {
			t.decl.refs++
		}
		for id := t.ids; id != nil; id = id.next {
			match id.store {
			case Dglobal, Dfn:
				modrefable(id.ty)
			case Dtype:
				if id.ty == nil || id.ty.kind != Tadt {
					continue
				}
				for m := id.ty.ids; m != nil; m = m.next {
					if m.store == Dfn {
						modrefable(m.ty)
					}
				}
			}
		}
	case Tfn, Tadt, Tadtpick, Ttuple:
		for id := t.ids; id != nil; id = id.next {
			if id.store != Dfn {
				modrefable(id.ty)
			}
		}
		for tg := t.tags; tg != nil; tg = tg.next {
			modrefable(tg.ty)
		}
		if t.kind == Tfn {
			modrefable(t.tof)
		}
	}
}

func narrowmods() {
	for eq := modclass(); eq != nil; eq = eq.eq {
		for id := eq.ty.ids; id != nil; id = id.next {
			if id.iface != nil {
				id.iface.refs += id.refs
			}
			if id.store == Dtype && id.ty != nil && id.ty.kind == Tadt {
				for m := id.ty.ids; m != nil; m = m.next {
					if m.iface != nil {
						m.iface.refs += m.refs
					}
				}
			}
		}
	}
	for eq := modclass(); eq != nil; eq = eq.eq {
		for id := eq.ty.ids; id != nil; id = id.next {
			if id.refs > 0 && (id.store == Dfn || id.store == Dglobal) {
				modrefable(id.ty)
			}
			if id.store == Dtype && id.ty != nil && id.ty.kind == Tadt {
				for m := id.ty.ids; m != nil; m = m.next {
					if m.store == Dfn && m.refs > 0 {
						modrefable(m.ty)
					}
				}
			}
		}
	}
	for eq := modclass(); eq != nil; eq = eq.eq {
		t := eq.ty.tof
		if t == nil {
			continue
		}
		if t.linkall == 0 {
			var last ref Decl
			for id := t.ids; id != nil; id = id.next {
				if id.refs == 0 {
					if last == nil {
						t.ids = id.next
					} else {
						last.next = id.next
					}
				} else {
					last = id
				}
			}
			t.ok &= ~OKsized
			sizetype(t)
		}
		offset := 0
		for id := t.ids; id != nil; id = id.next {
			id.offset = offset
			offset++
		}
		if t.decl != nil && t.decl.init != nil {
			t.decl.init.val = big(offset)
		}
	}
}

func teqclass(t ref Type) {
	if t == nil || (t.ok & OKclass) == OKclass {
		return
	}
	t.ok |= OKclass
	match t.kind {
	case Tref, Tchan, Tarray, Tlist:
		teqclass(t.tof)
		return
	case Tadt, Tadtpick, Ttuple, Texception:
		for id := t.ids; id != nil; id = id.next {
			teqclass(id.ty)
		}
		for tg := t.tags; tg != nil; tg = tg.next {
			teqclass(tg.ty)
		}
	case Tmodule:
		if t.tof == nil {
			t.tof = mkiface(t.decl)
		}
		for id := t.ids; id != nil; id = id.next {
			teqclass(id.ty)
		}
	case Tfn:
		for id := t.ids; id != nil; id = id.next {
			teqclass(id.ty)
		}
		teqclass(t.tof)
		return
	default:
		return
	}
	if (t.ok & OKsized) != OKsized {
		sys.fprint(sys.fildes(2), "fatal: eqclass type not sized: %s\n", tprint(t))
		return
	}
	for teq := eqclass[t.kind]; teq != nil; teq = teq.eq {
		if t.size == teq.ty.size && tequal(t, teq.ty) != 0 {
			t.eq = teq
			if t.kind == Tmodule {
				joiniface(t, t.eq.ty.tof)
			}
			return
		}
	}
	t.eq = ref Teq{id: 0, ty: t, eq: eqclass[t.kind]}
	eqclass[t.kind] = t.eq
}

func tequal(t1 ref Type, t2 ref Type) int {
	eqrec = 0
	eqset = 0
	ok := rtequal(t1, t2)
	cleareqrec(t1)
	cleareqrec(t2)
	eqset = 0
	return ok
}

func rtequal(t1 ref Type, t2 ref Type) int {
	if t1 == t2 {
		return 1
	}
	if t1 == nil || t2 == nil {
		return 0
	}
	if t1.kind == Terror || t2.kind == Terror {
		return 1
	}
	if t1.kind != t2.kind {
		return 0
	}
	if t1.eq != nil && t2.eq != nil {
		return t1.eq == t2.eq
	}
	t1.rec |= TReq
	t2.rec |= TReq
	match t1.kind {
	case Tnone, Tbig, Tbyte, Treal, Tint, Tstring:
		return 1
	case Tref, Tlist, Tarray, Tchan:
		if t1.kind != Tref && assumeteq(t1, t2) != 0 {
			return 1
		}
		return rtequal(t1.tof, t2.tof)
	case Tfn:
		if t1.varargs != t2.varargs {
			return 0
		}
		if idequal(t1.ids, t2.ids, 0, 1) == 0 {
			return 0
		}
		return rtequal(t1.tof, t2.tof)
	case Ttuple, Texception:
		if assumeteq(t1, t2) != 0 {
			return 1
		}
		return idequal(t1.ids, t2.ids, 0, 1)
	case Tadt, Tadtpick, Tmodule:
		if assumeteq(t1, t2) != 0 {
			return 1
		}
		if t1.kind == Tmodule {
			return idequal(t1.tof.ids, t2.tof.ids, 1, 0)
		}
		if t1.kind == Tadtpick && rtequal(t1.decl.dot.ty, t2.decl.dot.ty) == 0 {
			return 0
		}
		if idequal(t1.tags, t2.tags, 1, 0) == 0 {
			return 0
		}
		return idequal(t1.ids, t2.ids, 1, 1)
	}
	sys.fprint(sys.fildes(2), "fatal: unknown type %s v %s in rtequal\n", tprint(t1), tprint(t2))
	return 0
}

func assumeteq(t1 ref Type, t2 ref Type) int {
	if t1.teq == nil && t2.teq == nil {
		eqrec++
		eqset += 2
		t1.teq = t1
		t2.teq = t1
		return 0
	}
	if t1.teq == nil {
		r := t1
		t1 = t2
		t2 = r
	}
	r1 := t1.teq
	for r1 != r1.teq {
		r1 = r1.teq
	}
	r2 := t2.teq
	for r2 != nil && r2 != r2.teq {
		r2 = r2.teq
	}
	if r1 == r2 {
		return 1
	}
	if r2 == nil {
		eqset++
	}
	t2.teq = t1
	for t2 != r1 {
		r2 = t2.teq
		t2.teq = r1
		t2 = r2
	}
	return 0
}

// storeok: 1 to consider only declarations that occupy storage
func idequal(id1 ref Decl, id2 ref Decl, usenames int, storeok int) int {
	if id1 == id2 {
		return 1
	}
	for ; id1 != nil; id1 = id1.next {
		if storeok != 0 && storespace(id1.store) == 0 {
			continue
		}
		for id2 != nil && storeok != 0 && storespace(id2.store) == 0 {
			id2 = id2.next
		}
		if id2 == nil {
			return 0
		}
		if usenames != 0 && id1.sym != id2.sym {
			return 0
		}
		if id1.store != id2.store || id1.implicit != id2.implicit || id1.cyc != id2.cyc {
			return 0
		}
		if (id1.dot == nil) != (id2.dot == nil) {
			return 0
		}
		if id1.dot != nil && id2.dot != nil && id1.dot.ty.kind != id2.dot.ty.kind {
			return 0
		}
		if rtequal(id1.ty, id2.ty) == 0 {
			return 0
		}
		id2 = id2.next
	}
	for id2 != nil && storeok != 0 && storespace(id2.store) == 0 {
		id2 = id2.next
	}
	return id1 == nil && id2 == nil
}

func cleareqrec(t ref Type) int {
	n := 0
	for t != nil && (t.rec & TReq) == TReq {
		t.rec &= ~TReq
		if t.teq != nil {
			t.teq = nil
			n++
		}
		if t.kind == Tadtpick {
			n += cleareqrec(t.decl.dot.ty)
		}
		if t.kind == Tmodule {
			t = t.tof
		}
		for id := t.ids; id != nil; id = id.next {
			n += cleareqrec(id.ty)
		}
		for id := t.tags; id != nil; id = id.next {
			n += cleareqrec(id.ty)
		}
		t = t.tof
	}
	return n
}

func mkiface(m ref Decl) ref Type {
	iface := ref Decl{}
	last := iface
	globals := mkdecl(m.line, m.pos, Dglobal, mktype(m.line, m.pos, Tadt, nil, nil))
	glast := globals
	for id := m.ty.ids; id != nil; id = id.next {
		match id.store {
		case Dglobal:
			glast.next = dupdecl(id)
			glast = glast.next
			id.iface = globals
			glast.iface = id
		case Dfn:
			if id.tparams != nil || id.inl != 0 {
				break	// a template from an interface: no code to link
			}
			last.next = dupdecl(id)
			last = last.next
			id.iface = last
			last.iface = id
		case Dtype:
			if id.ty.kind != Tadt {
				continue
			}
			for d := id.ty.ids; d != nil; d = d.next {
				if d.store == Dfn {
					last.next = dupdecl(d)
					last = last.next
					d.iface = last
					last.iface = d
				}
			}
		}
	}
	last.next = nil
	ifl := namesort(iface.next)
	if globals.next != nil {
		glast.next = nil
		globals.ty.ids = namesort(globals.next)
		globals.ty.decl = globals
		globals.sym = ".mp"
		globals.dot = m
		globals.next = ifl
		ifl = globals
	}
	t := mktype(m.line, m.pos, Tiface, nil, ifl)
	name := ".m." + m.sym
	id := symdecl(name)
	if id == nil {
		id = mkdecl(m.line, m.pos, Dglobal, t)
		id.sym = name
		setsymdecl(name, id)
	}
	t.decl = id
	id.ty = t
	id.init = mkn(Onothing, nil, nil)
	id.init.ty = t
	id.init.decl = id
	return t
}

func joiniface(mt ref Type, t ref Type) {
	iface := t.ids
	globals := iface
	if iface != nil && iface.store == Dglobal {
		iface = iface.next
	}
	for id := mt.tof.ids; id != nil; id = id.next {
		match id.store {
		case Dglobal:
			for d := id.ty.ids; d != nil; d = d.next {
				d.iface.iface = globals
			}
		case Dfn:
			id.iface.iface = iface
			iface = iface.next
		default:
			sys.fprint(sys.fildes(2), "fatal: unknown store %d in joiniface\n", id.store)
		}
	}
	if iface != nil {
		sys.fprint(sys.fildes(2), "fatal: join iface not matched\n")
	}
	mt.tof = t
}

// signatures: the text rtsign() builds, then its MD5 folded to a word
func sigstring(t ref Type) string {
	eqrec = 0
	s := rtsign(t, "")
	v := clearrec(t)
	if v != eqrec {
		sys.fprint(sys.fildes(2), "fatal: recid not balanced in sign: %d %d\n", v, eqrec)
	}
	eqrec = 0
	return s
}

func sign(d ref Decl) int {
	t := d.ty
	if t.sig != 0 {
		return t.sig
	}
	s := sigstring(t)
	b := []byte(s)
	digest := [keyring.MD5dlen]byte
	keyring.md5(b, len(b), digest, nil)
	sig := 0
	for i := 0; i < keyring.MD5dlen; i += 4 {
		sig ^= int(digest[i]) | (int(digest[i+1]) << 8) | (int(digest[i+2]) << 16) | (int(digest[i+3]) << 24)
	}
	t.sig = sig
	return sig
}

func rtsign(t ref Type, sig string) string {
	if t == nil {
		return sig
	}
	if t.eq != nil && t.eq.id != 0 {
		if t.eq.id < 0 || t.eq.id > eqrec {
			sys.fprint(sys.fildes(2), "fatal: sign rec %s %d %d\n", tprint(t), t.eq.id, eqrec)
		}
		return sig + sys.sprint("%c%d", SIGREC, t.eq.id)
	}
	if t.eq != nil {
		eqrec++
		t.eq.id = eqrec
	}
	kind := sigkinds[t.kind]
	if kind == 0 {
		sys.fprint(sys.fildes(2), "fatal: no sigkind for %s\n", tprint(t))
	}
	sig += sys.sprint("%c", kind)
	t.rec = 1
	match t.kind {
	case Tnone, Tbig, Tbyte, Treal, Tint, Tstring, Tpoly:
		return sig
	case Tref, Tlist, Tarray, Tchan:
		return rtsign(t.tof, sig)
	case Tfn:
		if t.varargs != 0 {
			sig += sys.sprint("%c", SIGVARARGS)
		}
		ids := t.ids
		if t.hasenv != 0 && ids != nil {
			ids = ids.next
		}
		sig = idsign(ids, 0, sig)
		return rtsign(t.tof, sig)
	case Ttuple:
		return idsign(t.ids, 0, sig)
	case Tadt:
		if t.eq == nil {
			if t.decl.sym != ".mp" {
				sys.fprint(sys.fildes(2), "fatal: no t->eq field for %s\n", tprint(t))
			}
			sig = sig[0:len(sig)-1]
			for id := t.ids; id != nil; id = id.next {
				sig = idsign1(id, 1, sig) + ";"
			}
			return sig
		}
		sig = idsign(t.ids, 1, sig)
		if t.tags == nil {
			return sig
		}
		sig = sig[0:len(sig)-1] + ","
		for tg := t.tags; tg != nil; tg = tg.next {
			sig += tg.sym + "=>"
			sig = rtsign(tg.ty, sig)
			if tg.next != nil {
				sig += ","
			}
		}
		return sig + ")"
	case Tadtpick:
		sig = idsign(t.ids, 1, sig)
		return rtsign(t.decl.dot.ty, sig)
	case Tmodule:
		if t.tof.linkall == 0 {
			sys.fprint(sys.fildes(2), "fatal: signing a narrowed module\n")
		}
		sig += "{"
		for id := t.tof.ids; id != nil; id = id.next {
			if id.tag != 0 {
				continue
			}
			if id.sym == ".mp" {
				sig = rtsign(id.ty, sig)
				continue
			}
			sig = idsign1(id, 1, sig) + ";"
		}
		return sig + "}"
	}
	sys.fprint(sys.fildes(2), "fatal: bogus type %s in rtsign\n", tprint(t))
	return sig
}

func idsign(id ref Decl, usenames int, sig string) string {
	sig += "("
	first := 1
	for ; id != nil; id = id.next {
		if storespace(id.store) == 0 {
			continue
		}
		if first == 0 {
			sig += ","
		}
		sig = idsign1(id, usenames, sig)
		first = 0
	}
	return sig + ")"
}

func idsign1(id ref Decl, usenames int, sig string) string {
	if usenames != 0 {
		sig += id.sym + ":"
	}
	if id.implicit != 0 {
		sig += sys.sprint("%c", SIGSELF)
	}
	if id.cyc != 0 {
		sig += sys.sprint("%c", SIGCYC)
	}
	return rtsign(id.ty, sig)
}

func clearrec(t ref Type) int {
	n := 0
	for t != nil && t.rec != 0 {
		t.rec = 0
		if t.eq != nil && t.eq.id != 0 {
			t.eq.id = 0
			n++
		}
		if t.kind == Tmodule {
			for id := t.tof.ids; id != nil; id = id.next {
				n += clearrec(id.ty)
			}
			return n
		}
		if t.kind == Tadtpick {
			n += clearrec(t.decl.dot.ty)
		}
		for id := t.ids; id != nil; id = id.next {
			n += clearrec(id.ty)
		}
		for id := t.tags; id != nil; id = id.next {
			n += clearrec(id.ty)
		}
		t = t.tof
	}
	return n
}

// the diagnostic form of a type, ember/types.c's tprint()
func tprint(t ref Type) string {
	if t == nil {
		return "nil"
	}
	match t.kind {
	case Tref:
		if t.tof != nil && t.tof.kind == Tfn && t.tof.hasenv != 0 {
			// a closure value: its public shape
			s := "func("
			var id ref Decl
			if t.tof.ids != nil {
				id = t.tof.ids.next
			}
			for ; id != nil; id = id.next {
				s += tprint(id.ty)
				if id.next != nil {
					s += ", "
				}
			}
			s += ")"
			if t.tof.tof != nil && t.tof.tof.kind != Tnone {
				s += ": " + tprint(t.tof.tof)
			}
			return s
		}
		return "ref " + tprint(t.tof)
	case Tarray:
		return "array of " + tprint(t.tof)
	case Tlist:
		return "list of " + tprint(t.tof)
	case Tchan:
		return "chan of " + tprint(t.tof)
	case Tadtpick:
		// a tag's own type: Adt.Tag
		if t.decl != nil && t.decl.sym != nil && t.decl.dot != nil && t.decl.dot.sym != nil {
			return t.decl.dot.sym + "." + t.decl.sym
		}
		return kindname(t.kind)
	case Tadt, Tmodule, Tpoly:
		if t.decl != nil && t.decl.sym != nil {
			return t.decl.sym
		}
		return kindname(t.kind)
	case Ttuple:
		s := "("
		for id := t.ids; id != nil; id = id.next {
			s += tprint(id.ty)
			if id.next != nil {
				s += ", "
			}
		}
		return s + ")"
	case Tfn:
		s := "fn("
		for id := t.ids; id != nil; id = id.next {
			s += tprint(id.ty)
			if id.next != nil {
				s += ", "
			}
		}
		s += ")"
		if t.tof != nil && t.tof.kind != Tnone {
			s += ": " + tprint(t.tof)
		}
		return s
	}
	return kindname(t.kind)
}

// node constructors, ast.c's
func mkn(op int, left ref Node, right ref Node) ref Node {
	return ref Node{op: op, left: left, right: right}
}

func mkbin(op int, left ref Node, right ref Node) ref Node {
	n := mkn(op, left, right)
	n.line = left.line
	n.pos = left.pos
	return n
}

func mkunary(op int, left ref Node) ref Node {
	n := mkn(op, left, nil)
	n.line = left.line
	n.pos = left.pos
	return n
}

func mkseq(left ref Node, right ref Node) ref Node {
	if left == nil {
		return right
	}
	if right == nil {
		return left
	}
	return mkbin(Oseq, left, right)
}

func rotater(n ref Node) ref Node {
	if n == nil {
		return n
	}
	if n.op != Oseq {
		return n
	}
	for {
		left := n.left
		if left.op != Oseq {
			break
		}
		n.left = left.right
		left.right = n
		n = left
	}
	return n
}

// a copy is a new node: checked state doesn't carry over
func dupn(old ref Node) ref Node {
	return ref Node{op: old.op, left: old.left, right: old.right, aux: old.aux, sym: old.sym, val: old.val, rval: old.rval, flags: old.flags & ~NCHECKED, line: old.line, pos: old.pos, ty: old.ty, decl: old.decl, addable: old.addable, temps: old.temps}
}
