module Emberfmt

// the source formatter, in Ember: a port of ember/fmt.c.  print()
// writes the raw parse tree (parse.setfmt() first) formatted:
// tabs for indentation, one statement per line, canonical spacing,
// the comments and blank lines of the original kept in place.

import sys "sys"
import types "types"
import lex "lex"
import parse "parse"
import bufio "bufio"

var fb ref bufio.Iobuf
var indent = 0
var nextcom = 0
var lastline = 0
var comments []ref lex.Comment
var ncomments = 0

func out(s string) {
	fb.puts(s)
}

func tabs() {
	for i := 0; i < indent; i++ {
		fb.putc('\t')
	}
}

// comments that start before line, each on its own line
func comsbefore(line int) {
	for nextcom < ncomments && comments[nextcom].line < line {
		c := comments[nextcom]
		nextcom++
		if lastline > 0 && c.line > lastline + 1 {
			out("\n")
		}
		tabs()
		if c.block != 0 {
			out("/*" + c.text + "*/\n")
		} else {
			out("//" + c.text + "\n")
		}
		lastline = c.line
	}
}

// a comment on the same line, after what was just printed
func comsafter(line int) {
	for nextcom < ncomments && comments[nextcom].line == line {
		c := comments[nextcom]
		nextcom++
		if c.block != 0 {
			out("\t/*" + c.text + "*/")
		} else {
			out("\t//" + c.text)
		}
	}
}

// a block, match or alt knows its closing brace's line (parse.e
// stores it in val); anything else ends where it starts
func lastlineof(n ref types.Node) int {
	if n.stop > 0 {
		return n.stop
	}
	if (n.op == types.Oscope || n.op == types.Omatch || n.op == types.Oalt) && n.val > big(0) {
		return int(n.val)
	}
	return n.line
}

// a blank line where the source had one
func gap(n ref types.Node) {
	if lastline > 0 && n.line > lastline + 1 {
		out("\n")
	}
}

func item(p ref types.Node) ref types.Node {
	if p.op == types.Oseq {
		return p.left
	}
	return p
}

func names(n ref types.Node) {
	for ; n != nil; n = n.right {
		out(item(n).sym)
		if n.op != types.Oseq {
			break
		}
		out(", ")
	}
}

func fields(n ref types.Node, stmts int) {
	for ; n != nil; n = n.right {
		f := item(n)
		if stmts != 0 {
			comsbefore(f.line)
			tabs()
		}
		if f.left != nil {
			names(f.left)
			if f.right != nil {
				out(" ")
			}
		}
		if (f.flags & types.NVARARG) != 0 {
			out("...")
			if f.right != nil {
				typ(f.right)
			}
		} else if f.right != nil {
			typ(f.right)
		}
		if stmts != 0 {
			comsafter(f.line)
			out("\n")
			lastline = f.line
		} else if n.op == types.Oseq {
			out(", ")
		}
		if n.op != types.Oseq {
			break
		}
	}
}

func signature(n ref types.Node) {
	out("(")
	fields(n.left, 0)
	out(")")
	if n.right != nil {
		out(" ")
		typ(n.right)
	}
}

func ismaptype(n ref types.Node) bool {
	return n.op == types.Otref && n.right != nil && n.right.op == types.Otinst && (n.right.flags & types.NMAPT) != 0
}

func typ(n ref types.Node) {
	if n == nil {
		return
	}
	match n.op {
	case types.Oname:
		out(n.sym)
	case types.Odot:
		typ(n.left)
		out("." + n.right.sym)
	case types.Otinst:
		typ(n.left)
		out("[")
		for p := n.right; p != nil; p = p.right {
			typ(item(p))
			if p.op != types.Oseq {
				break
			}
			out(", ")
		}
		out("]")
	case types.Otarray:
		out("[]")
		typ(n.right)
	case types.Otlist:
		out("list ")
		typ(n.right)
	case types.Otchan:
		out("chan ")
		typ(n.right)
	case types.Otref:
		if ismaptype(n) {
			out("map[")
			typ(n.right.right.left)
			out("]")
			typ(n.right.right.right)
			return
		}
		out("ref ")
		typ(n.right)
	case types.Otfunc:
		out("func")
		signature(n)
	case types.Ottuple:
		out("(")
		for p := n.left; p != nil; p = p.right {
			typ(item(p))
			if p.op != types.Oseq {
				break
			}
			out(", ")
		}
		out(")")
	case types.Otstruct:
		if (n.flags & types.NIFACE) != 0 {
			out("interface {\n")
			indent++
			for p := n.left; p != nil; p = p.right {
				t := item(p)
				comsbefore(t.line)
				tabs()
				out(t.left.sym)
				if t.right != nil {	// an embedded interface is its name alone
					signature(t.right)
				}
				comsafter(t.line)
				out("\n")
				lastline = t.line
				if p.op != types.Oseq {
					break
				}
			}
			indent--
			tabs()
			out("}")
			return
		}
		out("struct {\n")
		indent++
		fields(n.left, 1)
		indent--
		tabs()
		out("}")
	case types.Otpick:
		out("pick {\n")
		indent++
		fields(n.right, 1)
		for p := n.left; p != nil; p = p.right {
			t := item(p)
			comsbefore(t.line)
			tabs()
			out(t.left.sym + "(")
			fields(t.right, 0)
			out(")")
			comsafter(t.line)
			out("\n")
			lastline = t.line
			if p.op != types.Oseq {
				break
			}
		}
		indent--
		tabs()
		out("}")
	default:
		expr(n, 0)
	}
}

func strlit(s string) {
	r := "\""
	for _, c := range s {
		match c {
		case '\\':
			r += "\\\\"
		case '"':
			r += "\\\""
		case '\n':
			r += "\\n"
		case '\t':
			r += "\\t"
		case '\r':
			r += "\\r"
		case 0:
			r += "\\0"
		default:
			r[len(r)] = c
		}
	}
	out(r + "\"")
}

func constant(n ref types.Node) {
	if (n.flags & types.NSTR) != 0 {
		strlit(n.sym)
		return
	}
	if (n.flags & types.NREAL) != 0 {
		s := sys.sprint("%g", n.rval)
		dotted := false
		for _, c := range s {
			if c == '.' || c == 'e' || c == 'n' {
				dotted = true
			}
		}
		out(dotted ? s : s + ".0")
		return
	}
	match n.temps {
	case lex.Fchar:
		v := int(n.val)
		match v {
		case '\'':
			out("'\\''")
		case '\\':
			out("'\\\\'")
		case '\n':
			out("'\\n'")
		case '\t':
			out("'\\t'")
		case '\r':
			out("'\\r'")
		case 0:
			out("'\\0'")
		default:
			if v >= ' ' && v < 0x7f {
				out(sys.sprint("'%c'", v))
			} else {
				out(sys.sprint("'\\u%.4ux'", v))
			}
		}
		return
	case lex.Fhex:
		out(sys.sprint("0x%bux", n.val))
		return
	case lex.Foct:
		out(sys.sprint("0o%buo", n.val))
		return
	case lex.Foct0:
		out(sys.sprint("0%buo", n.val))
		return
	case lex.Fbin:
		s := ""
		v := n.val
		for {
			s = sys.sprint("%d", int(v & big(1))) + s
			v >>= 1
			if v == big(0) {
				break
			}
		}
		out("0b" + s)
		return
	}
	out(sys.sprint("%bd", n.val))
}

// precedence of a binary op (parse.c's binprec); 9 = not binary
func precof(op int) int {
	match op {
	case types.Omul, types.Odiv, types.Omod, types.Olsh, types.Orsh, types.Oand:
		return 6
	case types.Oadd, types.Osub, types.Oor, types.Oxor:
		return 5
	case types.Oeq, types.Oneq, types.Olt, types.Oleq, types.Ogt, types.Ogeq:
		return 4
	case types.Ocons:
		return 3
	case types.Oandand:
		return 2
	case types.Ooror:
		return 1
	case types.Ocond:
		return 0
	}
	return 9
}

func opstr(op int) string {
	match op {
	case types.Omul:
		return "*"
	case types.Odiv:
		return "/"
	case types.Omod:
		return "%"
	case types.Olsh:
		return "<<"
	case types.Orsh:
		return ">>"
	case types.Oand:
		return "&"
	case types.Oadd:
		return "+"
	case types.Osub:
		return "-"
	case types.Oor:
		return "|"
	case types.Oxor:
		return "^"
	case types.Oeq:
		return "=="
	case types.Oneq:
		return "!="
	case types.Olt:
		return "<"
	case types.Oleq:
		return "<="
	case types.Ogt:
		return ">"
	case types.Ogeq:
		return ">="
	case types.Ocons:
		return "::"
	case types.Oandand:
		return "&&"
	case types.Ooror:
		return "||"
	case types.Oneg:
		return "-"
	case types.Onot:
		return "!"
	case types.Oinv:
		return "~"
	case types.Oaddas:
		return "+="
	case types.Osubas:
		return "-="
	case types.Omulas:
		return "*="
	case types.Odivas:
		return "/="
	case types.Omodas:
		return "%="
	case types.Oandas:
		return "&="
	case types.Ooras:
		return "|="
	case types.Oxoras:
		return "^="
	case types.Olshas:
		return "<<="
	case types.Orshas:
		return ">>="
	}
	return "?"
}

func exprlist(n ref types.Node) {
	for ; n != nil; n = n.right {
		e := item(n)
		expr(e, 0)
		if (e.flags & types.NVARARG) != 0 {
			out("...")
		}
		if n.op != types.Oseq {
			break
		}
		out(", ")
	}
}

func elems(n ref types.Node) {
	for ; n != nil; n = n.right {
		e := item(n)
		if e.left != nil {
			expr(e.left, 0)
			out(": ")
		}
		expr(e.right, 0)
		if n.op != types.Oseq {
			break
		}
		out(", ")
	}
}

func expr(n ref types.Node, prec int) {
	if n == nil {
		return
	}
	if n.op >= types.Otarray && n.op <= types.Otpick {
		typ(n)	// a type argument: f[[]int](x), Box[func(int) int]{}
		return
	}
	match n.op {
	case types.Oname:
		out(n.sym)
	case types.Oconst:
		constant(n)
	case types.Odot:
		expr(n.left, 8)
		out((n.val == big(1) ? "?." : ".") + n.right.sym)
	case types.Oassert:
		expr(n.left, 8)
		if n.val == big(2) {
			out(".(type)")	// a type switch's subject
			break
		}
		out(".(")
		typ(n.right)
		out(")")
	case types.Ocall:
		expr(n.left, 8)
		out("(")
		exprlist(n.right)
		out(")")
	case types.Oindex:
		expr(n.left, 8)
		out("[")
		exprlist(n.right)
		out("]")
	case types.Oslice:
		expr(n.left, 8)
		out("[")
		if n.right.left != nil {
			expr(n.right.left, 0)
		}
		out(":")
		if n.right.right != nil {
			expr(n.right.right, 0)
		}
		out("]")
	case types.Ochk:
		expr(n.left, 8)
		out("?")
	case types.Ocomposite, types.Omaplit:
		typ(n.left)
		out("{")
		elems(n.right)
		out("}")
	case types.Oarray:
		out("[")
		if n.val != big(1) {	// "[]T{...}" counted its own elements
			expr(n.left, 0)
		}
		out("]")
		typ(n.right)
		if n.aux != nil || n.val == big(1) {
			out("{")
			elems(n.aux)
			out("}")
		}
	case types.Ochan:
		out("chan")
		if n.left != nil {
			out("[")
			expr(n.left, 0)
			out("]")
		}
		out(" ")
		typ(n.right)
	case types.Ocast:
		typ(n.right)
		out("(")
		expr(n.left, 0)
		out(")")
	case types.Otuple:
		out("(")
		exprlist(n.left)
		out(")")
	case types.Ofunclit:
		out("func")
		signature(n.right)
		out(" ")
		block(n.aux)
	case types.Oload:
		out("load ")
		typ(n.left)
		out(" ")
		expr(n.right, 7)
	case types.Orange:
		out("range ")
		expr(n.left, 7)
	case types.Oref:
		out("ref ")
		expr(n.left, 7)
	case types.Orcv:
		out("<-")
		expr(n.left, 7)
	case types.Oneg, types.Onot, types.Oinv:
		out(opstr(n.op))
		expr(n.left, 7)
	case types.Ocond:
		if prec > 0 {
			out("(")
		}
		if n.val == big(1) {
			expr(n.left, 1)
			out(" ?? ")
			expr(n.aux, 1)
		} else {
			expr(n.left, 1)
			out(" ? ")
			expr(n.right, 0)
			out(" : ")
			expr(n.aux, 0)
		}
		if prec > 0 {
			out(")")
		}
	default:
		p := precof(n.op)
		if p == 9 {
			out("?" + parse.opname(n.op) + "?")
			return
		}
		if p < prec {
			out("(")
		}
		expr(n.left, p)
		out(" " + opstr(n.op) + " ")
		expr(n.right, n.op == types.Ocons ? p : p + 1)
		if p < prec {
			out(")")
		}
	}
}

func simple(n ref types.Node) {
	match n.op {
	case types.Oexpr:
		expr(n.left, 0)
	case types.Odas:
		exprlist(n.left)
		out(" := ")
		exprlist(n.right)
	case types.Oas:
		exprlist(n.left)
		out(" = ")
		exprlist(n.right)
	case types.Oaddas, types.Osubas, types.Omulas, types.Odivas, types.Omodas, types.Oandas, types.Ooras, types.Oxoras, types.Olshas, types.Orshas:
		expr(n.left, 0)
		out(" " + opstr(n.op) + " ")
		expr(n.right, 0)
	case types.Oinc:
		expr(n.left, 0)
		out("++")
	case types.Odec:
		expr(n.left, 0)
		out("--")
	case types.Osnd:
		expr(n.left, 0)
		out(" <- ")
		expr(n.right, 0)
	default:
		expr(n, 0)
	}
}

func stmts(n ref types.Node) {
	for ; n != nil; n = n.right {
		s := item(n)
		if s.op == types.Ocondecl && s.aux != nil {
			// a local const block
			comsbefore(s.aux.line)
			if lastline > 0 && s.aux.line > lastline + 1 {
				out("\n")
			}
			tabs()
			n = constblock(n)
			if n == nil {
				break
			}
			continue
		}
		stmt(s)
		if n.op != types.Oseq {
			break
		}
	}
}

func block(n ref types.Node) {
	out("{\n")
	indent++
	if n != nil && n.line > 0 {
		lastline = n.line	// the line of the brace: no gap before the first statement
	}
	if n != nil && n.op == types.Oscope {
		stmts(n.left)
	} else {
		stmts(n)
	}
	if n != nil {
		comsbefore(lastlineof(n) + 1)
	} else {
		comsbefore(0)
	}
	indent--
	tabs()
	out("}")
	if n != nil && lastlineof(n) > lastline {
		lastline = lastlineof(n)
	}
}

func cases(n ref types.Node, isalt int, istype int) {
	for ; n != nil; n = n.right {
		c := item(n)
		comsbefore(c.line)
		tabs()
		if c.left == nil {
			out("default:")
		} else {
			out("case ")
			if isalt != 0 {
				simple(c.left)
			} else {
				for p := c.left; p != nil; p = p.right {
					q := item(p)
					if istype != 0 {
						typ(q)	// a type switch's case
					} else if q.op == types.Opat {
						typ(q.left)
						if q.right != nil {
							out("(")
							names(q.right)
							out(")")
						}
					} else if q.op == types.Orange {
						expr(q.left, 0)
						out("...")
						expr(q.right, 0)
					} else {
						expr(q, 0)
					}
					if p.op != types.Oseq {
						break
					}
					out(", ")
				}
				if c.aux != nil {
					out(" if ")
					expr(c.aux, 0)
				}
			}
			out(":")
		}
		comsafter(c.line)
		out("\n")
		lastline = c.line
		indent++
		stmts(c.right)
		indent--
		if n.op != types.Oseq {
			break
		}
	}
}

func ifstmt(n ref types.Node) {
	out("if ")
	if n.left.op == types.Oseq {
		simple(n.left.left)
		out("; ")
		expr(n.left.right, 0)
	} else {
		expr(n.left, 0)
	}
	out(" ")
	block(n.right)
	if n.aux != nil {
		out(" else ")
		if n.aux.op == types.Oif {
			ifstmt(n.aux)
		} else {
			block(n.aux)
		}
	}
}

func stmt(n ref types.Node) {
	if n == nil {
		return
	}
	if n.op == types.Oseq {
		stmts(n)
		return
	}
	comsbefore(n.line)
	gap(n)
	tabs()
	if exporting != 0 {
		out("export ")
	}
	match n.op {
	case types.Oscope:
		block(n.left)
	case types.Oif:
		ifstmt(n)
	case types.Ofor:
		out("for")
		if n.aux != nil && n.aux.op == types.Odas {
			out(" ")
			simple(n.aux)
		} else if n.aux != nil && n.aux.op == types.Oforctl {
			out(" ")
			if n.aux.left != nil {
				simple(n.aux.left)
			}
			out("; ")
			if n.left != nil {
				expr(n.left, 0)
			}
			if n.aux.right != nil && n.aux.right.val == big(1) {
				out("")	// implied post: for init; cond {
			} else {
				out(";")
				if n.aux.right != nil {
					out(" ")
					simple(n.aux.right)
				}
			}
		} else if n.left != nil {
			out(" ")
			expr(n.left, 0)
		}
		out(" ")
		block(n.right)
	case types.Omatch:
		out("match ")
		if n.aux != nil {
			simple(n.aux)
			out("; ")
		}
		istype := 0
		if n.left.op == types.Oassert && n.left.val == big(2) {
			istype = 1
			if n.left.right != nil {
				out(n.left.right.sym + " := ")	// the type switch's binder
			}
		}
		expr(n.left, 0)
		out(" {\n")
		lastline = n.line
		cases(n.right, 0, istype)
		tabs()
		out("}")
	case types.Oalt:
		out("alt {\n")
		lastline = n.line
		cases(n.right, 1, 0)
		tabs()
		out("}")
	case types.Obreak:
		out("break")
		if n.left != nil {
			out(" " + n.left.sym)
		}
	case types.Ocont:
		out("continue")
		if n.left != nil {
			out(" " + n.left.sym)
		}
	case types.Oret:
		out("return")
		if n.left != nil {
			out(" ")
			exprlist(n.left)
		}
	case types.Oraise:
		out("raise ")
		expr(n.left, 0)
	case types.Ospawn:
		out("spawn ")
		expr(n.left, 0)
	case types.Odefer:
		out("defer ")
		expr(n.left, 0)
	case types.Otry:
		out("try ")
		block(n.left)
		out(" catch ")
		if n.aux != nil {
			out(n.aux.sym + " ")
		}
		block(n.right)
	case types.Olabel:
		out(n.left.sym + ":\n")
		lastline = n.line
		stmt(n.right)
		return
	case types.Ovardecl:
		out("var ")
		names(n.left)
		if n.right != nil {
			out(" ")
			typ(n.right)
		}
		if n.aux != nil {
			out(" = ")
			exprlist(n.aux)
		}
	case types.Ocondecl:
		out("const " + n.left.sym + " = ")
		expr(n.right, 0)
	case types.Otypedecl:
		out("type " + n.left.sym)
		if n.aux != nil {
			out("[")
			names(n.aux)
			out("]")
		}
		out(" ")
		typ(n.right)
	default:
		simple(n)
	}
	// a statement with blocks ends where its last block did
	end := lastlineof(n)
	if lastline > end {
		end = lastline
	}
	comsafter(end)
	out("\n")
	lastline = end
}

// a run of const-block items (pcondecl marks them with aux)
func constblock(p ref types.Node) ref types.Node {
	d := item(p)
	if (d.val & big(2)) != big(0) {
		out("export ")
	}
	out("const (\n")
	indent++
	lastline = d.aux.line	// the "const (" line
	for ; p != nil; p = p.right {
		d = item(p)
		if d.op != types.Ocondecl || d.aux == nil {
			break
		}
		comsbefore(d.line)
		gap(d)
		tabs()
		out(d.left.sym)
		if (d.val & big(1)) == big(0) {
			out(" = ")
			expr(d.right, 0)
		}
		comsafter(d.line)
		out("\n")
		lastline = d.line
		if p.op != types.Oseq {
			indent--
			tabs()
			out(")\n")
			return nil
		}
		// the next item ends the block when its aux index restarts at 0
		if p.right != nil {
			nd := item(p.right)
			if nd.op != types.Ocondecl || nd.aux == nil || nd.aux.val == big(0) {
				break
			}
		}
	}
	indent--
	tabs()
	out(")\n")
	return p
}

var exporting = 0	// stmt() prefixes "export " to the declaration decl() handed it

func decl(n ref types.Node) {
	if n.op != types.Oimport && n.op != types.Ofndecl {
		// type, var and const declarations print as statements, which space themselves
		exporting = int(n.val & big(2))
		indent = 0
		stmt(n)
		exporting = 0
		return
	}
	comsbefore(n.line)
	gap(n)
	if (n.val & big(2)) != big(0) {
		out("export ")
	}
	match n.op {
	case types.Oimport:
		if n.left != nil {
			out("import " + n.left.sym + " ")
		} else {
			out("import ")
		}
		strlit(n.right.sym)
		out("\n")
	case types.Ofndecl:
		out("func ")
		if n.left.op == types.Omethod {
			out("(")
			fields(n.left.left, 0)
			out(") " + n.left.right.sym)
		} else {
			out(n.left.sym)
		}
		if n.right.aux != nil {
			out("[")
			names(n.right.aux)
			out("]")
		}
		signature(n.right)
		if n.aux != nil {
			out(" ")
			block(n.aux)
		}
		out("\n")
	}
	end := lastlineof(n)
	if lastline > end {
		end = lastline
	}
	comsafter(end)
	lastline = end
}

func print(fd int, tree ref types.Node, cms []ref lex.Comment, ncms int) {
	fb = bufio.fopen(sys.fildes(fd), bufio.OWRITE)
	indent = 0
	nextcom = 0
	lastline = 0
	comments = cms
	ncomments = ncms
	comsbefore(tree.line)
	out("module " + tree.left.sym + "\n")
	lastline = tree.line
	for p := tree.right; p != nil; {
		d := item(p)
		if d.op == types.Ocondecl && d.aux != nil {
			comsbefore(d.aux.line)
			if lastline > 0 && d.aux.line > lastline + 1 {
				out("\n")
			}
			p = constblock(p)
			if p == nil {
				break
			}
			p = p.right
			continue
		}
		decl(d)
		if p.op != types.Oseq {
			break
		}
		p = p.right
	}
	comsbefore(1 << 30)
	fb.flush()
}
