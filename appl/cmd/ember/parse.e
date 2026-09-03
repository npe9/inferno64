module Parse

import sys "sys"
import lex "lex"
import types "types"

// a port of ember/parse.c, function for function, over the
// self-hosted lexer with the same two-token lookahead.  a Node keeps
// only its start position; parse.c also records the end, which no
// later pass reads.

const NREAL = 1
const NSTR = 2
const NVARARG = 4

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


var opnames = [101]string{"none", "module", "import", "typedecl", "vardecl", "condecl", "fndecl", "method", "field", "tag", "tarray", "tchan", "tlist", "tref", "tfunc", "ttuple", "tinst", "tstruct", "tpick", "scope", "seq", "if", "for", "forctl", "match", "alt", "case", "pat", "break", "continue", "return", "spawn", "send", "das", "as", "addas", "subas", "mulas", "divas", "modas", "andas", "oras", "xoras", "lshas", "rshas", "inc", "dec", "expr", "label", "raise", "name", "const", "nil", "dot", "mdot", "call", "index", "inds", "indx", "slice", "composite", "elem", "funclit", "tuple", "chk", "rcv", "ref", "load", "len", "hd", "tl", "cons", "cast", "neg", "not", "inv", "add", "sub", "mul", "div", "mod", "and", "or", "xor", "lsh", "rsh", "andand", "oror", "eq", "neq", "lt", "gt", "leq", "geq", "ind", "adr", "used", "nothing", "chan", "array", "end"}

var lx ref lex.Lexer
var look0 ref lex.Tok
var look1 ref lex.Tok
var nlook = 0
var noblit = 0
var nerrors = 0
var infile = ""

func opname(op int) string {
	if op < 0 || op >= len(opnames) {
		return sys.sprint("op%d", op)
	}
	return opnames[op]
}

func errors() int {
	return nerrors
}

func error(line int, msg string) {
	nerrors++
	sys.fprint(sys.fildes(2), "%s:%d: %s\n", infile, line, msg)
}

// two-token lookahead over the lexer, as lex.c's lexlook()/lexskip()
func fill() {
	if nlook == 0 {
		look0 = lx.next()
		nlook = 1
	}
	if nlook == 1 {
		look1 = lx.next()
		nlook = 2
	}
}

func tk() ref lex.Tok {
	fill()
	return look0
}

func cur() int {
	fill()
	return look0.t
}

func nxt() int {
	fill()
	return look1.t
}

func lexskip() {
	fill()
	look0 = look1
	nlook = 1
	fill()
}




func mkname(t ref lex.Tok, s string) ref types.Node {
	n := types.mkn(Oname, nil, nil)
	n.line = t.line
	n.pos = t.pos
	n.sym = s
	return n
}

func mkconst(t ref lex.Tok, v big) ref types.Node {
	n := types.mkn(Oconst, nil, nil)
	n.line = t.line
	n.pos = t.pos
	n.val = v
	return n
}

func mkrconst(t ref lex.Tok, r real) ref types.Node {
	n := types.mkn(Oconst, nil, nil)
	n.line = t.line
	n.pos = t.pos
	n.rval = r
	n.flags |= NREAL
	return n
}

func mksconst(t ref lex.Tok, s string) ref types.Node {
	n := types.mkn(Oconst, nil, nil)
	n.line = t.line
	n.pos = t.pos
	n.sym = s
	n.flags |= NSTR
	return n
}

func mknil(t ref lex.Tok) ref types.Node {
	return mkname(t, "nil")
}



func synerr(msg string) {
	error(tk().line, sys.sprint("near ` %s ` : %s", lex.tokname(cur()), msg))
}

func paccept(t int) int {
	if cur() != t {
		return 0
	}
	lexskip()
	return 1
}

// consume t or report it missing; returns the token that was there
func pexpect(t int, ctx string) ref lex.Tok {
	tok := tk()
	if cur() == t {
		lexskip()
		return tok
	}
	error(tok.line, sys.sprint("expected %s in %s, near ` %s `", lex.tokname(t), ctx, lex.tokname(cur())))
	return tok
}

// skip to the end of the statement or block after an error
func psync() {
	depth := 0
	for {
		match cur() {
		case lex.Beof:
			return
		case '{', '(', '[':
			depth++
		case ')', ']':
			if depth > 0 {
				depth--
			}
		case '}':
			if depth == 0 {
				return
			}
			depth--
		case ';':
			if depth == 0 {
				lexskip()
				return
			}
		}
		lexskip()
	}
}

func pname(ctx string) ref types.Node {
	t := tk()
	if t.t != lex.Eid {
		error(t.line, sys.sprint("expected identifier in %s, near ` %s `", ctx, lex.tokname(t.t)))
		n := mkname(t, "?")
		psync()
		return n
	}
	n := mkname(t, t.sym)
	lexskip()
	return n
}

func pnamelist(ctx string) ref types.Node {
	n := pname(ctx)
	for paccept(',') != 0 {
		n = types.mkseq(n, pname(ctx))
	}
	return n
}

// a possibly qualified, possibly instantiated type name
func ptypename() ref types.Node {
	n := pname("type name")
	for paccept('.') != 0 {
		d := pname("qualified type name")
		n = types.mkbin(Odot, n, d)
		n.sym = d.sym
	}
	if cur() == '[' {
		lexskip()
		args := ptype()
		for paccept(',') != 0 {
			args = types.mkseq(args, ptype())
		}
		pexpect(']', "type arguments")
		n = types.mkbin(Otinst, n, types.rotater(args))
	}
	return n
}

func pfield() ref types.Node {
	ids := pnamelist("field declaration")
	t := ptype()
	return types.mkbin(Ofield, types.rotater(ids), t)
}

func pfields(ctx string) ref types.Node {
	var n ref types.Node
	for cur() != '}' && cur() != lex.Beof {
		if paccept(';') != 0 {
			continue
		}
		n = types.mkseq(n, pfield())
		if cur() != '}' {
			pexpect(';', ctx)
		}
	}
	return types.rotater(n)
}

func ptag() ref types.Node {
	name := pname("pick member")
	var fields ref types.Node
	if cur() == '(' {
		lexskip()
		for cur() != ')' && cur() != lex.Beof {
			f := pfield()
			fields = types.mkseq(fields, f)
			if paccept(',') == 0 {
				break
			}
		}
		pexpect(')', "pick member fields")
	}
	return types.mkn(Otag, name, types.rotater(fields))
}

func psignature(named int) ref types.Node {
	var params ref types.Node
	src := pexpect('(', "function signature")
	for cur() != ')' && cur() != lex.Beof {
		if paccept(lex.Edots) != 0 {
			p := types.mkn(Ofield, nil, nil)
			p.line = src.line
			p.pos = src.pos
			p.flags |= NVARARG
			params = types.mkseq(params, p)
			break
		}
		var p ref types.Node
		if named != 0 {
			ids := pnamelist("parameter")
			if paccept(lex.Edots) != 0 {
				t := ptype()
				p = types.mkbin(Ofield, types.rotater(ids), t)
				p.flags |= NVARARG
			} else {
				t := ptype()
				p = types.mkbin(Ofield, types.rotater(ids), t)
			}
		} else {
			t := ptype()
			p = types.mkn(Ofield, nil, t)
			p.line = t.line
			p.pos = t.pos
		}
		params = types.mkseq(params, p)
		if paccept(',') == 0 {
			break
		}
	}
	pexpect(')', "function signature")
	var results ref types.Node
	match cur() {
	case '(':
		rt := tk()
		lexskip()
		results = ptype()
		for paccept(',') != 0 {
			results = types.mkseq(results, ptype())
		}
		pexpect(')', "function results")
		results = types.mkn(Ottuple, types.rotater(results), nil)
		results.line = rt.line
		results.pos = rt.pos
	case '{', ';', ',', ')', lex.Beof:
		results = nil
	default:
		results = ptype()
	}
	return types.mkn(Otfunc, types.rotater(params), results)
}

// an index expression or a type argument: a type no expression can
// start is parsed as one (parse.c)
func ptypearg() ref types.Node {
	match cur() {
	case lex.Kfunc, lex.Klist, lex.Kchan:
		return ptype()
	case '[':
		if nxt() == ']' {
			return ptype()
		}
	}
	return pexpr()
}

func ptype() ref types.Node {
	src := tk()
	match cur() {
	case '[':
		lexskip()
		pexpect(']', "array type")
		t := ptype()
		n := types.mkn(Otarray, nil, t)
		n.line = src.line
		n.pos = src.pos
		return n
	case lex.Kchan:
		lexskip()
		t := ptype()
		n := types.mkn(Otchan, nil, t)
		n.line = src.line
		n.pos = src.pos
		return n
	case lex.Klist:
		lexskip()
		t := ptype()
		n := types.mkn(Otlist, nil, t)
		n.line = src.line
		n.pos = src.pos
		return n
	case lex.Kref:
		lexskip()
		t := ptype()
		n := types.mkn(Otref, nil, t)
		n.line = src.line
		n.pos = src.pos
		return n
	case lex.Kfunc:
		lexskip()
		n := psignature(0)
		n.line = src.line
		n.pos = src.pos
		return n
	case lex.Kstruct:
		lexskip()
		pexpect('{', "struct type")
		n := types.mkn(Otstruct, pfields("struct field"), nil)
		n.line = src.line
		n.pos = src.pos
		pexpect('}', "struct type")
		return n
	case lex.Kpick:
		lexskip()
		pexpect('{', "pick type")
		var tags ref types.Node
		for cur() != '}' && cur() != lex.Beof {
			if paccept(';') != 0 {
				continue
			}
			tags = types.mkseq(tags, ptag())
			if cur() != '}' {
				pexpect(';', "pick member")
			}
		}
		n := types.mkn(Otpick, types.rotater(tags), nil)
		n.line = src.line
		n.pos = src.pos
		pexpect('}', "pick type")
		return n
	case '(':
		lexskip()
		n := ptype()
		for paccept(',') != 0 {
			n = types.mkseq(n, ptype())
		}
		n = types.mkn(Ottuple, types.rotater(n), nil)
		n.line = src.line
		n.pos = src.pos
		pexpect(')', "tuple type")
		return n
	case lex.Eid:
		return ptypename()
	}
	synerr("expected a type")
	psync()
	return mkname(src, "?")
}

// could the expression parsed so far be a type name, making a
// following "{" a composite literal?
func istypeexpr(n ref types.Node) int {
	match n.op {
	case Oname:
		return 1
	case Odot:
		if n.left != nil {
			return istypeexpr(n.left)
		}
		return 0
	case Oindex, Otinst:
		return istypeexpr(n.left)
	}
	return 0
}

func pcomposite(ty ref types.Node) ref types.Node {
	oblit := noblit
	noblit = 0
	pexpect('{', "composite literal")
	var elems ref types.Node
	for cur() != '}' && cur() != lex.Beof {
		var key ref types.Node
		if cur() == lex.Eid && nxt() == ':' {
			key = pname("element key")
			lexskip()
		}
		e := types.mkn(Oelem, key, pexpr())
		elems = types.mkseq(elems, e)
		if paccept(',') == 0 && cur() != ';' {
			break
		}
		paccept(';')
	}
	pexpect('}', "composite literal")
	noblit = oblit
	n := types.mkn(Ocomposite, ty, types.rotater(elems))
	n.line = ty.line
	n.pos = ty.pos
	return n
}

func poperand() ref types.Node {
	t := tk()
	match t.t {
	case lex.Econst:
		n := mkconst(t, t.ival)
		lexskip()
		return n
	case lex.Erconst:
		n := mkrconst(t, t.rval)
		lexskip()
		return n
	case lex.Esconst:
		n := mksconst(t, t.sym)
		lexskip()
		return n
	case lex.Knil:
		n := mknil(t)
		lexskip()
		return n
	case lex.Eid:
		n := mkname(t, t.sym)
		lexskip()
		return n
	case '(':
		lexskip()
		oblit := noblit
		noblit = 0
		n := pexpr()
		if paccept(',') != 0 {
			n = types.mkseq(n, pexpr())
			for paccept(',') != 0 {
				n = types.mkseq(n, pexpr())
			}
			n = types.mkn(Otuple, types.rotater(n), nil)
		}
		noblit = oblit
		n.line = t.line
		n.pos = t.pos
		pexpect(')', "parenthesised expression")
		return n
	case lex.Kfunc:
		lexskip()
		sig := psignature(1)
		oblit := noblit
		noblit = 0
		body := pblock()
		noblit = oblit
		n := types.mkn(Ofunclit, nil, sig)
		n.aux = body
		n.line = t.line
		n.pos = t.pos
		return n
	case lex.Kload:
		lexskip()
		tn := ptypename()
		n := types.mkn(Oload, tn, punary())
		n.line = t.line
		n.pos = t.pos
		return n
	case lex.Kchan:
		lexskip()
		var sz ref types.Node
		if cur() == '[' {
			lexskip()
			sz = pexpr()
			pexpect(']', "channel size")
		}
		te := ptype()
		n := types.mkn(Ochan, sz, te)
		n.line = t.line
		n.pos = t.pos
		return n
	case '[':
		lexskip()
		if cur() == ']' {
			// "[]byte(expr)": a conversion to an array type
			lexskip()
			te := ptype()
			pexpect('(', "conversion")
			e := pexpr()
			pexpect(')', "conversion")
			n := types.mkn(Ocast, e, types.mkn(Otarray, nil, te))
			n.right.line = te.line
			n.right.pos = te.pos
			n.line = t.line
			n.pos = t.pos
			return n
		}
		sz := pexpr()
		pexpect(']', "array size")
		te := ptype()
		n := types.mkn(Oarray, sz, te)
		n.line = t.line
		n.pos = t.pos
		if cur() == '{' {
			oblit := noblit
			noblit = 0
			pexpect('{', "array composite literal")
			var elems ref types.Node
			for cur() != '}' && cur() != lex.Beof {
				e := types.mkn(Oelem, nil, pexpr())
				elems = types.mkseq(elems, e)
				if paccept(',') == 0 && cur() != ';' {
					break
				}
				paccept(';')
			}
			pexpect('}', "array composite literal")
			noblit = oblit
			n.aux = types.rotater(elems)
		}
		return n
	}
	synerr("expected an expression")
	psync()
	return mkconst(t, big(0))
}

func pprimary() ref types.Node {
	n := poperand()
	for {
		match cur() {
		case '.':
			lexskip()
			e := pname("selector")
			n = types.mkbin(Odot, n, e)
			n.sym = e.sym
			continue
		case '(':
			lexskip()
			oblit := noblit
			noblit = 0
			var args ref types.Node
			for cur() != ')' && cur() != lex.Beof {
				args = types.mkseq(args, pexpr())
				if paccept(',') == 0 {
					break
				}
			}
			noblit = oblit
			pexpect(')', "call")
			e := types.mkn(Ocall, n, types.rotater(args))
			e.line = n.line
			e.pos = n.pos
			n = e
			continue
		case '[':
			lexskip()
			oblit := noblit
			noblit = 0
			var lo ref types.Node
			if cur() != ':' {
				lo = ptypearg()
			}
			if paccept(':') != 0 {
				var hi ref types.Node
				if cur() != ']' {
					hi = pexpr()
				}
				noblit = oblit
				pexpect(']', "slice")
				e := types.mkn(Oslice, n, types.mkn(Oseq, lo, hi))
				e.line = n.line
				e.pos = n.pos
				n = e
				continue
			}
			for paccept(',') != 0 {
				lo = types.mkseq(lo, ptypearg())
			}
			noblit = oblit
			pexpect(']', "index")
			e := types.mkn(Oindex, n, types.rotater(lo))
			e.line = n.line
			e.pos = n.pos
			n = e
			continue
		case '?':
			lexskip()
			n = types.mkunary(Ochk, n)
			continue
		case '{':
			if noblit != 0 || istypeexpr(n) == 0 {
				break
			}
			n = pcomposite(n)
			continue
		}
		break
	}
	return n
}

func punary() ref types.Node {
	src := tk()
	op := 0
	match cur() {
	case '-':
		op = Oneg
	case '!':
		op = Onot
	case '~':
		op = Oinv
	case '+':
		lexskip()
		return punary()
	case lex.Ecomm:
		lexskip()
		n := types.mkunary(Orcv, punary())
		n.line = src.line
		n.pos = src.pos
		return n
	case lex.Kref:
		lexskip()
		n := types.mkunary(Oref, punary())
		n.line = src.line
		n.pos = src.pos
		return n
	default:
		return pprimary()
	}
	lexskip()
	n := types.mkunary(op, punary())
	n.line = src.line
	n.pos = src.pos
	return n
}

// precedence of a binary operator token and its op, 0 if none
func binprec(t int) (int, int) {
	match t {
	case '*':
		return 6, Omul
	case '/':
		return 6, Odiv
	case '%':
		return 6, Omod
	case lex.Elsh:
		return 6, Olsh
	case lex.Ersh:
		return 6, Orsh
	case '&':
		return 6, Oand
	case '+':
		return 5, Oadd
	case '-':
		return 5, Osub
	case '|':
		return 5, Oor
	case '^':
		return 5, Oxor
	case lex.Eeq:
		return 4, Oeq
	case lex.Eneq:
		return 4, Oneq
	case '<':
		return 4, Olt
	case lex.Eleq:
		return 4, Oleq
	case '>':
		return 4, Ogt
	case lex.Egeq:
		return 4, Ogeq
	case lex.Econs:
		return 3, Ocons
	case lex.Eandand:
		return 2, Oandand
	case lex.Eoror:
		return 1, Ooror
	}
	return 0, 0
}

func pbinary(prec int) ref types.Node {
	n := punary()
	for {
		p, op := binprec(cur())
		if p == 0 || p < prec {
			return n
		}
		lexskip()
		next := p + 1
		if op == Ocons {
			next = p
		}
		r := pbinary(next)
		n = types.mkbin(op, n, r)
	}
	return n
}

func pexpr() ref types.Node {
	return pbinary(1)
}

func pexprlist() ref types.Node {
	n := pexpr()
	for paccept(',') != 0 {
		n = types.mkseq(n, pexpr())
	}
	return types.rotater(n)
}

func pvardecl() ref types.Node {
	src := pexpect(lex.Kvar, "var declaration")
	ids := types.rotater(pnamelist("var declaration"))
	var t ref types.Node
	if cur() != '=' && cur() != ';' {
		t = ptype()
	}
	var init ref types.Node
	if paccept('=') != 0 {
		init = pexprlist()
	}
	if t == nil && init == nil {
		synerr("var declaration needs a type or initializer")
	}
	n := types.mkn(Ovardecl, ids, t)
	n.aux = init
	n.line = src.line
	n.pos = src.pos
	return n
}

func pcondecl() ref types.Node {
	src := pexpect(lex.Kconst, "const declaration")
	name := pname("const declaration")
	pexpect('=', "const declaration")
	n := types.mkn(Ocondecl, name, pexpr())
	n.line = src.line
	n.pos = src.pos
	return n
}

func ptypedecl() ref types.Node {
	src := pexpect(lex.Ktype, "type declaration")
	name := pname("type declaration")
	var polys ref types.Node
	if paccept('[') != 0 {
		polys = types.rotater(pnamelist("type parameters"))
		pexpect(']', "type parameters")
	}
	n := types.mkn(Otypedecl, name, ptype())
	n.aux = polys
	n.line = src.line
	n.pos = src.pos
	return n
}

// a simple statement: an expression, or an assignment, declaration,
// send, increment built on one
func psimple() ref types.Node {
	lhs := pexprlist()
	op := 0
	match cur() {
	case lex.Edeclas:
		lexskip()
		return types.mkbin(Odas, lhs, pexprlist())
	case '=':
		lexskip()
		return types.mkbin(Oas, lhs, pexprlist())
	case lex.Eaddeq:
		op = Oaddas
	case lex.Esubeq:
		op = Osubas
	case lex.Emuleq:
		op = Omulas
	case lex.Ediveq:
		op = Odivas
	case lex.Emodeq:
		op = Omodas
	case lex.Eandeq:
		op = Oandas
	case lex.Eoreq:
		op = Ooras
	case lex.Exoreq:
		op = Oxoras
	case lex.Elsheq:
		op = Olshas
	case lex.Ersheq:
		op = Orshas
	case lex.Einc:
		lexskip()
		return types.mkunary(Oinc, lhs)
	case lex.Edec:
		lexskip()
		return types.mkunary(Odec, lhs)
	case lex.Ecomm:
		lexskip()
		return types.mkbin(Osnd, lhs, pexpr())
	default:
		return types.mkunary(Oexpr, lhs)
	}
	lexskip()
	return types.mkbin(op, lhs, pexpr())
}

func pif() ref types.Node {
	src := pexpect(lex.Kif, "if statement")
	oblit := noblit
	noblit = 1
	var init ref types.Node
	var cond ref types.Node
	n := psimple()
	if paccept(';') != 0 {
		init = n
		n = psimple()
	}
	if n.op == Oexpr {
		cond = n.left
	} else {
		error(n.line, "if condition must be an expression")
		cond = mkconst(src, big(0))
	}
	noblit = oblit
	then := pblock()
	var els ref types.Node
	if paccept(lex.Kelse) != 0 {
		if cur() == lex.Kif {
			els = pif()
		} else {
			els = pblock()
		}
	}
	n = types.mkn(Oif, cond, then)
	n.aux = els
	n.line = src.line
	n.pos = src.pos
	if init != nil {
		n = types.mkn(Oscope, types.mkseq(init, n), nil)
		n.line = src.line
		n.pos = src.pos
	}
	return n
}

func pfor() ref types.Node {
	src := pexpect(lex.Kfor, "for statement")
	oblit := noblit
	noblit = 1
	var init ref types.Node
	var cond ref types.Node
	var post ref types.Node
	if cur() != '{' {
		three := 0
		if cur() == ';' {
			lexskip()
			three = 1
		} else {
			e := psimple()
			if paccept(';') != 0 {
				init = e
				three = 1
			} else if e.op == Oexpr {
				cond = e.left
			} else {
				error(e.line, "for condition must be an expression")
			}
		}
		if three != 0 {
			if cur() != ';' {
				e := psimple()
				if e.op == Oexpr {
					cond = e.left
				} else {
					error(e.line, "for condition must be an expression")
				}
			}
			pexpect(';', "for clause")
			if cur() != '{' {
				post = psimple()
			}
		}
	}
	noblit = oblit
	body := pblock()
	n := types.mkn(Ofor, cond, body)
	if init != nil || post != nil {
		n.aux = types.mkn(Oforctl, init, post)
	}
	n.line = src.line
	n.pos = src.pos
	return n
}

func ppattern() ref types.Node {
	t := tk()
	match t.t {
	case lex.Econst:
		v := t.ival
		lexskip()
		return mkconst(t, v)
	case '-':
		lexskip()
		t2 := tk()
		if t2.t != lex.Econst {
			synerr("expected an integer constant pattern")
			psync()
			return mkconst(t, big(0))
		}
		v := t2.ival
		lexskip()
		return mkconst(t, -v)
	case lex.Esconst:
		s := t.sym
		lexskip()
		return mksconst(t, s)
	case lex.Knil:
		lexskip()
		return mknil(t)
	case lex.Eid:
		n := ptypename()
		var ids ref types.Node
		if paccept('(') != 0 {
			if cur() != ')' {
				ids = types.rotater(pnamelist("pattern binders"))
			}
			pexpect(')', "pattern")
		}
		n = types.mkn(Opat, n, ids)
		n.line = t.line
		n.pos = t.pos
		return n
	}
	synerr("expected a pattern")
	psync()
	return mkconst(t, big(0))
}

func pcases(ctx string, isalt int) ref types.Node {
	var cases ref types.Node
	for cur() != '}' && cur() != lex.Beof {
		if paccept(';') != 0 {
			continue
		}
		csrc := tk()
		var pats ref types.Node
		if paccept(lex.Kdefault) != 0 {
			pats = nil
		} else {
			pexpect(lex.Kcase, ctx)
			if isalt != 0 {
				pats = psimple()
			} else {
				pats = ppattern()
				for paccept(',') != 0 {
					pats = types.mkseq(pats, ppattern())
				}
				pats = types.rotater(pats)
			}
		}
		pexpect(':', ctx)
		var stmts ref types.Node
		for cur() != lex.Kcase && cur() != lex.Kdefault && cur() != '}' && cur() != lex.Beof {
			if paccept(';') != 0 {
				continue
			}
			stmts = types.mkseq(stmts, pstmt())
		}
		c := types.mkn(Ocase, pats, types.rotater(stmts))
		c.line = csrc.line
		c.pos = csrc.pos
		cases = types.mkseq(cases, c)
	}
	return types.rotater(cases)
}

func pmatch() ref types.Node {
	src := pexpect(lex.Kmatch, "match statement")
	oblit := noblit
	noblit = 1
	subj := pexpr()
	noblit = oblit
	pexpect('{', "match statement")
	cases := pcases("match case", 0)
	n := types.mkn(Omatch, subj, cases)
	n.line = src.line
	n.pos = src.pos
	pexpect('}', "match statement")
	return n
}

func palt() ref types.Node {
	src := pexpect(lex.Kalt, "alt statement")
	pexpect('{', "alt statement")
	cases := pcases("alt case", 1)
	n := types.mkn(Oalt, nil, cases)
	n.line = src.line
	n.pos = src.pos
	pexpect('}', "alt statement")
	return n
}

func pstmt() ref types.Node {
	t := tk()
	var n ref types.Node
	match t.t {
	case ';':
		lexskip()
		return nil
	case '{':
		n = types.mkn(Oscope, pblock(), nil)
		n.line = t.line
		n.pos = t.pos
		return n
	case lex.Kvar:
		n = pvardecl()
	case lex.Kconst:
		n = pcondecl()
	case lex.Ktype:
		n = ptypedecl()
	case lex.Kif:
		return pif()
	case lex.Kfor:
		return pfor()
	case lex.Kmatch:
		return pmatch()
	case lex.Kalt:
		return palt()
	case lex.Kbreak:
		lexskip()
		n = types.mkn(Obreak, nil, nil)
		n.line = t.line
		n.pos = t.pos
		if cur() == lex.Eid {
			n.left = pname("break label")
		}
	case lex.Kcontinue:
		lexskip()
		n = types.mkn(Ocont, nil, nil)
		n.line = t.line
		n.pos = t.pos
		if cur() == lex.Eid {
			n.left = pname("continue label")
		}
	case lex.Kreturn:
		lexskip()
		n = types.mkn(Oret, nil, nil)
		n.line = t.line
		n.pos = t.pos
		if cur() != ';' && cur() != '}' {
			n.left = pexprlist()
		}
	case lex.Kraise:
		lexskip()
		n = types.mkunary(Oraise, pexpr())
		n.line = t.line
		n.pos = t.pos
	case lex.Kspawn:
		lexskip()
		e := pprimary()
		if e.op != Ocall {
			error(e.line, "spawn requires a function call")
		}
		n = types.mkunary(Ospawn, e)
		n.line = t.line
		n.pos = t.pos
	case lex.Eid:
		if nxt() == ':' {
			n = pname("label")
			lexskip()
			n = types.mkn(Olabel, n, pstmt())
			n.line = t.line
			n.pos = t.pos
			return n
		}
		n = psimple()
	default:
		n = psimple()
	}
	if cur() != '}' {
		pexpect(';', "statement")
	}
	return n
}

func pblock() ref types.Node {
	src := pexpect('{', "block")
	var n ref types.Node
	for cur() != '}' && cur() != lex.Beof {
		n = types.mkseq(n, pstmt())
	}
	b := types.mkn(Oscope, types.rotater(n), nil)
	b.line = src.line
	b.pos = src.pos
	pexpect('}', "block")
	return b
}

func pfndecl() ref types.Node {
	src := pexpect(lex.Kfunc, "function declaration")
	var recv ref types.Node
	if paccept('(') != 0 {
		recv = types.mkn(Ofield, pname("receiver"), ptype())
		pexpect(')', "receiver")
	}
	name := pname("function declaration")
	if recv != nil {
		name = types.mkbin(Omethod, recv, name)
	}
	var polys ref types.Node
	if paccept('[') != 0 {
		polys = types.rotater(pnamelist("type parameters"))
		pexpect(']', "type parameters")
	}
	sig := psignature(1)
	sig.aux = polys
	var body ref types.Node
	if cur() == '{' {
		body = pblock()
	}
	n := types.mkn(Ofndecl, name, sig)
	n.aux = body
	n.line = src.line
	n.pos = src.pos
	return n
}

func pimport() ref types.Node {
	src := pexpect(lex.Kimport, "import declaration")
	var name ref types.Node
	if cur() == lex.Eid {
		name = pname("import declaration")
	}
	t := tk()
	if t.t != lex.Esconst {
		synerr("expected import path string")
		psync()
		return nil
	}
	path := mksconst(t, t.sym)
	lexskip()
	n := types.mkn(Oimport, name, path)
	n.line = src.line
	n.pos = src.pos
	return n
}

func parse(file string) ref types.Node {
	infile = file
	nerrors = 0
	nlook = 0
	noblit = 0
	lx = lex.open(file)
	if lx == nil {
		sys.fprint(sys.fildes(2), "ember: can't open %s\n", file)
		nerrors++
		return nil
	}
	src := pexpect(lex.Kmodule, "module clause")
	name := pname("module clause")
	pexpect(';', "module clause")
	prog := types.mkn(Omodule, name, nil)
	prog.line = src.line
	prog.pos = src.pos
	var n ref types.Node
	for cur() != lex.Beof {
		match cur() {
		case ';':
			lexskip()
			continue
		case lex.Kimport:
			n = types.mkseq(n, pimport())
		case lex.Ktype:
			n = types.mkseq(n, ptypedecl())
		case lex.Kvar:
			n = types.mkseq(n, pvardecl())
		case lex.Kconst:
			n = types.mkseq(n, pcondecl())
		case lex.Kfunc:
			n = types.mkseq(n, pfndecl())
		default:
			synerr("expected a declaration")
			psync()
			continue
		}
		if cur() != lex.Beof {
			pexpect(';', "declaration")
		}
	}
	prog.right = types.rotater(n)
	nerrors += lx.errors
	return prog
}
