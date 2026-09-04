module Ifacegen

// "emberc -i file.e": derive the module's interface file (.ei) from its
// checked declarations, in source order: imports, constants, types
// (interfaces printed as declared), variables, and the signatures of
// functions and methods.  Generic and inline declarations carry
// bodies an interface must repeat, so they are left to be written by
// hand, with a comment saying so.  Hidden names (leading '.') are
// the compiler's own and are skipped, except an interface's struct,
// which stands for the interface.  a port of ember/ifacegen.c; the
// names are resolved through the checker's scope, where the C
// compiler reads them off the symbol.

import sys "sys"
import bufio "bufio"
import types "types"
import check "check"

var ib ref bufio.Iobuf

// the driver's checker instance: its scope holds the module's names,
// this module's own import would be an empty one
func usecheck(c Check) {
	check = c
}

func out(s string) {
	ib.puts(s)
}

func aliasof(m ref types.Decl) string {
	if m == nil || m == check.moduledecl() {
		return ""
	}
	for l := check.importlist(); l != nil; l = tl(l) {
		if hd(l).importid == m {
			return hd(l).sym
		}
	}
	return m.sym
}

func hidden(s string) bool {
	return len(s) > 0 && s[0] == '.'
}

func paramsrc(id ref types.Decl, skip int) {
	first := 1
	for ; id != nil; id = id.next {
		if skip > 0 {
			skip--
			continue
		}
		if first == 0 {
			out(", ")
		}
		first = 0
		if id.sym != "" && !hidden(id.sym) {
			out(id.sym + " ")
		}
		tsrc(id.ty)
	}
}

func fnsrc(t ref types.Type, skip int) {
	out("(")
	paramsrc(t.ids, skip)
	out(")")
	if t.tof != nil && t.tof.kind != types.Tnone {
		out(" ")
		tsrc(t.tof)
	}
}

func tsrc(t ref types.Type) {
	if t == nil {
		out("nil")
		return
	}
	match t.kind {
	case types.Tint:
		out("int")
	case types.Tbig:
		out("big")
	case types.Tbyte:
		out("byte")
	case types.Treal:
		out("real")
	case types.Tstring:
		out("string")
	case types.Tbool:
		out("bool")
	case types.Tref:
		if t.tof != nil && t.tof.kind == types.Tfn && t.tof.hasenv != 0 {
			out("func")
			fnsrc(t.tof, 1)
			return
		}
		if t.tof != nil && t.tof.kind == types.Tadt && t.tof.ismap != 0 {
			// map[K]V: the key and value types from the entry
			ent := t.tof.ids.ty.tof.tof
			out("map[")
			tsrc(ent.ids.ty)
			out("]")
			tsrc(ent.ids.next.ty)
			return
		}
		if t.tof != nil && t.tof.kind == types.Tadt && t.tof.isiface != 0 && t.tof.decl != nil {
			// ref .W$s is the interface W
			s := t.tof.decl.sym
			alias := aliasof(t.tof.decl.dot)
			if alias != "" {
				out(alias + ".")
			}
			out(s[1:len(s) - 2])
			return
		}
		out("ref ")
		tsrc(t.tof)
	case types.Tarray:
		out("[]")
		tsrc(t.tof)
	case types.Tlist:
		out("list ")
		tsrc(t.tof)
	case types.Tchan:
		out("chan ")
		tsrc(t.tof)
	case types.Tadtpick:
		alias := ""
		if t.decl != nil && t.decl.dot != nil {
			alias = aliasof(t.decl.dot.dot)
		}
		if alias != "" {
			out(alias + ".")
		}
		out(t.decl.dot.sym + "." + t.decl.sym)
	case types.Tadt, types.Tpoly:
		if t.decl != nil && t.decl.sym != "" {
			alias := aliasof(t.decl.dot)
			if alias != "" {
				out(alias + ".")
			}
			out(t.decl.sym)
			if t.gtemplate != nil && t.ginst != nil {
				// an instance: Box[int]
				out("[")
				for i := 0; i < t.ginst.nargs; i++ {
					if i > 0 {
						out(", ")
					}
					tsrc(t.ginst.args[i])
				}
				out("]")
			}
			return
		}
		out(types.kindname(t.kind))
	case types.Ttuple:
		out("(")
		for id := t.ids; id != nil; id = id.next {
			tsrc(id.ty)
			if id.next != nil {
				out(", ")
			}
		}
		out(")")
	case types.Tfn:
		out("func")
		fnsrc(t, 0)
	default:
		out(types.kindname(t.kind))
	}
}

func fieldsrc(id ref types.Decl, indent string) {
	for ; id != nil; id = id.next {
		out(indent + id.sym + " ")
		tsrc(id.ty)
		out("\n")
	}
}

func strlit(s string) string {
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
		default:
			r[len(r)] = c
		}
	}
	return r + "\""
}

func constsrc(n ref types.Node) {
	if (n.flags & types.NSTR) != 0 {
		out(strlit(n.sym))
		return
	}
	if (n.flags & types.NREAL) != 0 {
		out(sys.sprint("%g", n.rval))
		return
	}
	if n.ty != nil && n.ty.kind == types.Tbig {
		out(sys.sprint("big(%bd)", n.val))
	} else {
		out(sys.sprint("%bd", n.val))
	}
}

func typesrc(d ref types.Decl) {
	t := d.ty
	s := d.sym
	if t.kind == types.Tadt && t.isiface != 0 {
		// .W$s: print the interface it stands for
		out("type " + s[1:len(s) - 2] + " interface {\n")
		for m := t.ids; m != nil; m = m.next {
			if hidden(m.sym) {
				continue	// .self and .tag, the converter's own
			}
			out("\t" + m.sym)
			fnsrc(m.ty.tof, 1)
			out("\n")
		}
		out("}\n\n")
		return
	}
	if hidden(s) {
		return
	}
	if d.tparams != nil || (t.kind == types.Tadt && t.tparams != nil) {
		out("// generic type " + s + ": an interface repeats its body; write it by hand\n\n")
		return
	}
	if t.kind == types.Tadt && t.tags != nil {
		out("type " + s + " pick {\n")
		fieldsrc(t.ids, "\t")
		for tg := t.tags; tg != nil; tg = tg.next {
			out("\t" + tg.sym + "(")
			paramsrc(tg.ty.ids, 0)
			out(")\n")
		}
		out("}\n\n")
		return
	}
	if t.kind == types.Tadt && t.decl == d {
		out("type " + s + " struct {\n")
		fieldsrc(t.ids, "\t")
		out("}\n\n")
		return
	}
	out("type " + s + " ")
	tsrc(t)
	out("\n\n")
}

func methodsrc(d ref types.Decl, tname string) {
	if d.tparams != nil {
		out("// generic method " + tname + "." + d.sym + ": write it by hand\n")
		return
	}
	recv := d.ty.ids
	out("func (" + recv.sym + " ")
	tsrc(recv.ty)
	out(") " + d.sym)
	fnsrc(d.ty, 1)
	out("\n")
}

// the module's declaration of a top-level name: the checker leaves
// the module scope in place, so its binding is still the one
func moddecl(name string, store int) ref types.Decl {
	d := check.lookup(name)
	if d != nil && d.store == store {
		return d
	}
	return nil
}

func item(p ref types.Node) ref types.Node {
	if p.op == types.Oseq {
		return p.left
	}
	return p
}

func ifacegen(tree ref types.Node, fd int) {
	ib = bufio.fopen(sys.fildes(fd), bufio.OWRITE)
	anyexport := 0
	for p := tree.right; p != nil; p = p.right {
		if (item(p).val & big(2)) != big(0) {
			anyexport = 1
		}
		if p.op != types.Oseq {
			break
		}
	}
	out("module " + tree.left.sym + "\n\n")
	out("// derived by ember -i; generic and inline declarations are not\n// derived, an interface must carry their bodies\n\n")
	n := 0
	for p := tree.right; p != nil; p = p.right {
		decl := item(p)
		if decl.op == types.Oimport {
			if decl.left != nil {
				out("import " + decl.left.sym + " \"" + decl.right.sym + "\"\n")
			} else {
				out("import \"" + decl.right.sym + "\"\n")
			}
			n++
		}
		if p.op != types.Oseq {
			break
		}
	}
	if n > 0 {
		out("\n")
	}
	for p := tree.right; p != nil; p = p.right {
		decl := item(p)
		if anyexport != 0 && (decl.val & big(2)) == big(0) && decl.op != types.Oimport {
			if p.op != types.Oseq {
				break
			}
			continue	// not exported
		}
		match decl.op {
		case types.Ocondecl:
			if hidden(decl.left.sym) || decl.right.op != types.Oconst {
				break
			}
			out("const " + decl.left.sym + " = ")
			constsrc(decl.right)
			out("\n")
		case types.Otypedecl:
			d := moddecl(decl.left.sym, types.Dtype)
			if d == nil {
				break
			}
			if d.ty.kind == types.Tref && d.ty.tof != nil && d.ty.tof.kind == types.Tadt && d.ty.tof.isiface != 0 {
				break	// "type W ref .W$s": the interface was printed with its struct
			}
			typesrc(d)
			if d.ty.kind == types.Tadt && d.ty.isiface == 0 && !hidden(d.sym) {
				// meths is prepended: print in declaration order
				var ms list ref types.Decl
				for m := d.ty.meths; m != nil; m = m.link {
					ms = m :: ms
				}
				for ; ms != nil; ms = tl(ms) {
					methodsrc(hd(ms), d.sym)
				}
				if d.ty.meths != nil {
					out("\n")
				}
			}
		case types.Ovardecl:
			for names := decl.left; names != nil; names = names.right {
				id := item(names)
				d := moddecl(id.sym, types.Dglobal)
				if d != nil {
					out("var " + d.sym + " ")
					tsrc(d.ty)
					out("\n")
				}
				if names.op != types.Oseq {
					break
				}
			}
		case types.Ofndecl:
			if decl.left.op == types.Omethod {
				break	// printed with its type
			}
			if hidden(decl.left.sym) {
				break
			}
			d := moddecl(decl.left.sym, types.Dfn)
			if d == nil {
				break
			}
			if d.tparams != nil {
				out("// generic function " + d.sym + ": write it by hand\n")
				break
			}
			if d.sym == "init" {
				break
			}
			out("func " + d.sym)
			fnsrc(d.ty, 0)
			out("\n")
		}
		if p.op != types.Oseq {
			break
		}
	}
	ib.flush()
}
