module Iface

import sys "sys"
import types "types"
import parse "parse"
import fold "fold"

func usetypes(t Types) {
	types = t
	fold.usetypes(t)
}

// "map[K]V", "Result[T]", "Vec[int]" in an interface file: the
// generic machinery lives in the checker, which hands its own
// resolver over (check.e's ifacetinst).  a function rather than the
// module, since the checker already imports this one
var tinst func(ref types.Node, ref types.Decl) ref types.Type

func usetinst(f func(ref types.Node, ref types.Decl) ref types.Type) {
	tinst = f
}

// a port of ember/iface.c.  the C version publishes the builtin type
// names on the symbol table while binding an interface; here itype()
// resolves them by name.  constants fold through fold.foldconstexpr()
// after the interface's own earlier constants are substituted.

type Icache struct {
	path string
	d ref types.Decl
}

var ifaces list ref Icache
var incdirs list string
var rawfn = 0	// the next Otfunc is a function declaration's own signature
var nerrors = 0

func ifaceerrors() int {
	return nerrors
}

func addincpath(dir string) {
	// keep search order: append
	var r list string
	for l := incdirs; l != nil; l = tl(l) {
		r = hd(l) :: r
	}
	r = dir :: r
	incdirs = nil
	for ; r != nil; r = tl(r) {
		incdirs = hd(r) :: incdirs
	}
}

func exists(path string) int {
	fd := sys.open(path, sys.OREAD)
	if fd == nil {
		return 0
	}
	return 1
}

// find the interface file for an import path
func openiface(path string) string {
	if len(path) > 0 && (path[0] == '/' || path[0] == '.') {
		if exists(path) != 0 {
			return path
		}
		return nil
	}
	for l := incdirs; l != nil; l = tl(l) {
		p := hd(l) + "/" + path
		if exists(p) != 0 {
			return p
		}
		if len(path) < 3 || path[len(path)-3:] != ".ei" {
			p = hd(l) + "/" + path + ".ei"
			if exists(p) != 0 {
				return p
			}
		}
	}
	if exists(path) != 0 {
		return path
	}
	if len(path) < 3 || path[len(path)-3:] != ".ei" {
		if exists(path + ".ei") != 0 {
			return path + ".ei"
		}
	}
	return nil
}

var infile = ""

func error(line int, msg string) {
	nerrors++
	sys.fprint(sys.fildes(2), "%s:%d: %s\n", infile, line, msg)
}

func installmember(mod ref types.Decl, d ref types.Decl) {
	// a module's members share one namespace, methods included (a
	// method is called through the module alias), so two of the
	// same name are ambiguous -- the loader would link one of them
	// for both, silently
	for e := mod.ty.ids; e != nil; e = e.next {
		if e.sym == d.sym {
			error(d.line, sys.sprint("%s is declared twice in this interface (a method shares the module's names)", d.sym))
			break
		}
	}
	d.dot = mod
	d.next = nil
	if mod.ty.ids == nil {
		mod.ty.ids = d
		return
	}
	e := mod.ty.ids
	for e.next != nil {
		e = e.next
	}
	e.next = d
}

func findtype(mod ref types.Decl, s string) ref types.Decl {
	for id := mod.ty.ids; id != nil; id = id.next {
		if id.sym == s && id.store == types.Dtype {
			return id
		}
	}
	return nil
}

func builtin(name string) ref types.Type {
	match name {
	case "int":
		return types.basic(types.Tint)
	case "big":
		return types.basic(types.Tbig)
	case "byte":
		return types.basic(types.Tbyte)
	case "real":
		return types.basic(types.Treal)
	case "string":
		return types.basic(types.Tstring)
	case "bool":
		return types.basic(types.Tbool)
	}
	return nil
}

func ifields(n ref types.Node, mod ref types.Decl, store int) ref types.Decl {
	var ids ref types.Decl
	var last ref types.Decl
	for ; n != nil; n = n.right {
		f := n
		if n.op == types.Oseq {
			f = n.left
		}
		if f.op != types.Ofield {
			error(f.line, "bad field in interface")
			break
		}
		t := itype(f.right, mod)
		for names := f.left; names != nil; names = names.right {
			id := names
			if names.op == types.Oseq {
				id = names.left
			}
			d := types.mkdecl(id.line, id.pos, store, t)
			d.sym = id.sym
			d.dot = mod
			if ids == nil {
				ids = d
			} else {
				last.next = d
			}
			last = d
			if names.op != types.Oseq {
				break
			}
		}
		if n.op != types.Oseq {
			break
		}
	}
	return ids
}

func itype(n ref types.Node, mod ref types.Decl) ref types.Type {
	if n == nil {
		return types.basic(types.Tnone)
	}
	match n.op {
	case types.Otarray:
		return types.mktype(n.line, n.pos, types.Tarray, itype(n.right, mod), nil)
	case types.Otchan:
		return types.mktype(n.line, n.pos, types.Tchan, itype(n.right, mod), nil)
	case types.Otlist:
		return types.mktype(n.line, n.pos, types.Tlist, itype(n.right, mod), nil)
	case types.Otref:
		return types.mktype(n.line, n.pos, types.Tref, itype(n.right, mod), nil)
	case types.Otstruct:
		t := types.mktype(n.line, n.pos, types.Tadt, nil, ifields(n.left, mod, types.Dfield))
		t.ok |= types.OKverify
		if (n.flags & types.NIFACE) != 0 {
			t.isiface = 1	// an interface type (parse.e's pinterface)
		}
		return t
	case types.Otpick:
		t := types.mktype(n.line, n.pos, types.Tadt, nil, nil)
		t.ok |= types.OKverify
		return t
	case types.Ottuple:
		var idl ref types.Decl
		var last ref types.Decl
		i := 0
		for p := n.left; p != nil; p = p.right {
			tn := p
			if p.op == types.Oseq {
				tn = p.left
			}
			d := types.mkdecl(tn.line, tn.pos, types.Dfield, itype(tn, mod))
			d.sym = sys.sprint("t%d", i)
			i++
			if idl == nil {
				idl = d
			} else {
				last.next = d
			}
			last = d
			if p.op != types.Oseq {
				break
			}
		}
		return types.mktype(n.line, n.pos, types.Ttuple, nil, idl)
	case types.Otfunc:
		raw := rawfn
		rawfn = 0
		var args ref types.Decl
		var last ref types.Decl
		ft := types.mktype(n.line, n.pos, types.Tfn, types.basic(types.Tnone), nil)
		for p := n.left; p != nil; p = p.right {
			f := p
			if p.op == types.Oseq {
				f = p.left
			}
			if (f.flags & types.NVARARG) != 0 && f.right == nil && f.left == nil {
				ft.varargs = 1
				if p.op != types.Oseq {
					break
				}
				continue
			}
			if (f.flags & types.NVARARG) != 0 {
				ft.varargs = 1
			}
			t := itype(f.right, mod)
			if f.left == nil {
				// an unnamed parameter of a function type (iface.c)
				d := types.mkdecl(f.line, f.pos, types.Darg, t)
				d.sym = nil
				if args == nil {
					args = d
				} else {
					last.next = d
				}
				last = d
			} else {
				for ids := f.left; ids != nil; ids = ids.right {
					nid := ids
					if ids.op == types.Oseq {
						nid = ids.left
					}
					d := types.mkdecl(nid.line, nid.pos, types.Darg, t)
					d.sym = nid.sym
					if args == nil {
						args = d
					} else {
						last.next = d
					}
					last = d
					if ids.op != types.Oseq {
						break
					}
				}
			}
			if p.op != types.Oseq {
				break
			}
		}
		ft.ids = args
		if n.right != nil {
			ft.tof = itype(n.right, mod)
		}
		if raw != 0 {
			return ft
		}
		// a value type: the closure shape, as check.e's stype()
		return types.mktype(n.line, n.pos, types.Tref, types.envfn(n.line, n.pos, ft), nil)
	case types.Oname:
		if mod != nil && mod.ty != nil {
			for id := mod.ty.ids; id != nil; id = id.next {
				if id.sym == n.sym && id.store == types.Dtype {
					return id.ty
				}
			}
		}
		b := builtin(n.sym)
		if b != nil {
			return b
		}
		error(n.line, sys.sprint("unknown type %s", n.sym))
		return types.basic(types.Terror)
	case types.Odot:
		if mod != nil && mod.ty != nil && n.left != nil && n.left.op == types.Oname {
			var id ref types.Decl
			for id = mod.ty.ids; id != nil; id = id.next {
				if id.store == types.Dimport && id.sym == n.left.sym {
					break
				}
			}
			if id == nil {
				error(n.line, sys.sprint("%s is not an imported interface", n.left.sym))
				return types.basic(types.Terror)
			}
			tname := n.sym
			if n.right != nil {
				tname = n.right.sym
			}
			d := findtype(id.importid, tname)
			if d == nil {
				error(n.line, sys.sprint("%s has no type %s", n.left.sym, tname))
				return types.basic(types.Terror)
			}
			return d.ty
		}
		error(n.line, "bad qualified type")
		return types.basic(types.Terror)
	}
	if n.op == types.Otinst && tinst != nil {
		return tinst(n, mod)	// a generic instantiation: the checker resolves it
	}
	error(n.line, sys.sprint("unsupported interface type %s", types.opname(n.op)))
	return types.basic(types.Terror)
}

// replace, in a constant's initializer, every name of one of mod's
// own already-declared constants by a copy of that constant's literal
func iconstnames(n ref types.Node, mod ref types.Decl) {
	if n == nil {
		return
	}
	if n.op == types.Oname {
		for id := mod.ty.ids; id != nil; id = id.next {
			if id.store == types.Dconst && id.sym == n.sym && id.init != nil && id.init.op == types.Oconst {
				line := n.line
				pos := n.pos
				c := id.init
				n.op = c.op
				n.left = nil
				n.right = nil
				n.aux = nil
				n.sym = c.sym
				n.val = c.val
				n.rval = c.rval
				n.flags = c.flags
				n.ty = c.ty
				n.line = line
				n.pos = pos
				return
			}
		}
		return
	}
	iconstnames(n.left, mod)
	iconstnames(n.right, mod)
}

func bindiface(mod ref types.Decl, tree ref types.Node) {
	// pass 1: imports, and a placeholder type for every type name
	for n := tree.right; n != nil; n = n.right {
		decl := n
		if n.op == types.Oseq {
			decl = n.left
		}
		if decl.op == types.Oimport {
			m := readiface(decl.right.sym)
			if m == nil {
				error(decl.line, sys.sprint("cannot import %s", decl.right.sym))
			} else {
				alias := m.sym
				if decl.left != nil {
					alias = decl.left.sym
				}
				a := types.mkdecl(decl.line, decl.pos, types.Dimport, m.ty)
				a.sym = alias
				a.importid = m
				installmember(mod, a)
				if findtype(mod, m.sym) == nil {
					a = types.mkdecl(decl.line, decl.pos, types.Dtype, m.ty)
					a.sym = m.sym
					installmember(mod, a)
				}
			}
		}
		if decl.op == types.Otypedecl && findtype(mod, decl.left.sym) == nil {
			td := types.mkdecl(decl.line, decl.pos, types.Dtype, nil)
			td.sym = decl.left.sym
			td.ty = types.mktype(decl.line, decl.pos, types.Tadt, nil, nil)
			td.ty.decl = td
			if decl.aux != nil {
				// a generic type: a template from here on
				td.ty.tparams = decl.aux
				td.ty.tbody = decl.right
			}
			installmember(mod, td)
		}
		if n.op != types.Oseq {
			break
		}
	}

	for n := tree.right; n != nil; n = n.right {
		decl := n
		if n.op == types.Oseq {
			decl = n.left
		}
		match decl.op {
		case types.Otypedecl:
			td := findtype(mod, decl.left.sym)
			if td == nil {
				error(decl.line, "typedecl missing after pass 1")
				break
			}
			t := td.ty
			if decl.aux != nil {
				// a generic type: a template instantiated by each importer (iface.c)
				if decl.right.op != types.Otstruct && decl.right.op != types.Otpick {
					error(decl.line, sys.sprint("generic type %s: only struct and pick bodies are supported", decl.left.sym))
					break
				}
				t.kind = types.Tadt
				t.tparams = decl.aux
				t.tbody = decl.right
				break
			}
			if decl.right.op == types.Otstruct {
				t.kind = types.Tadt
				t.ids = ifields(decl.right.left, mod, types.Dfield)
				t.ok |= types.OKverify
				if (decl.right.flags & types.NIFACE) != 0 {
					t.isiface = 1
				}
			} else if decl.right.op == types.Otpick {
				t.kind = types.Tadt
				t.ok |= types.OKverify
				var tags ref types.Decl
				var last ref types.Decl
				ntag := 0
				for p := decl.right.left; p != nil; p = p.right {
					tg := p
					if p.op == types.Oseq {
						tg = p.left
					}
					tag := types.mkdecl(tg.line, tg.pos, types.Dtag, nil)
					tag.sym = tg.left.sym
					tag.tag = ntag
					ntag++
					tag.ty = types.mktype(tg.line, tg.pos, types.Tadtpick, nil, ifields(tg.right, mod, types.Dfield))
					tag.ty.tof = t
					tag.ty.decl = tag
					tag.dot = td
					if tags == nil {
						tags = tag
					} else {
						last.next = tag
					}
					last = tag
					if p.op != types.Oseq {
						break
					}
				}
				t.tags = tags
			} else {
				// "type Path string": the base type entire, as iface.c's "*t = *nt"
				nt := itype(decl.right, mod)
				types.copytype(t, nt)
				t.decl = td
			}
		case types.Ocondecl:
			d := types.mkdecl(decl.line, decl.pos, types.Dconst, nil)
			d.sym = decl.left.sym
			iconstnames(decl.right, mod)
			fold.foldconstexpr(decl.right)
			d.init = decl.right
			if decl.right.op == types.Oconst {
				if (decl.right.flags & types.NSTR) != 0 {
					d.ty = types.basic(types.Tstring)
				} else if (decl.right.flags & types.NREAL) != 0 {
					d.ty = types.basic(types.Treal)
				} else {
					d.ty = types.basic(types.Tint)	// as ember/iface.c: every integer constant is an int
				}
				decl.right.ty = d.ty
			} else {
				d.ty = types.tunknownt()
			}
			installmember(mod, d)
		case types.Ovardecl:
			t := itype(decl.right, mod)
			for names := decl.left; names != nil; names = names.right {
				id := names
				if names.op == types.Oseq {
					id = names.left
				}
				d := types.mkdecl(id.line, id.pos, types.Dglobal, t)
				d.sym = id.sym
				installmember(mod, d)
				if names.op != types.Oseq {
					break
				}
			}
		case types.Ofndecl:
			if decl.left.op == types.Omethod && (decl.right == nil || decl.right.aux == nil) {
				rty := decl.left.left.right
				if rty.op == types.Otref {
					rty = rty.right
				}
				if rty.op == types.Otinst || rty.op == types.Oindex {
					// a generic type's method with its body: a template
					// on the type template (iface.c)
					if decl.aux == nil {
						error(decl.line, sys.sprint("method %s of a generic type in an interface needs its body: it is instantiated in each importer", decl.left.right.sym))
						break
					}
					var btd ref types.Decl
					if rty.left.op == types.Oname {
						btd = findtype(mod, rty.left.sym)
					}
					if btd == nil || btd.ty == nil || btd.ty.tparams == nil {
						error(decl.line, sys.sprint("receiver of %s is not a generic type of this interface", decl.left.right.sym))
						break
					}
					d := types.mkdecl(decl.line, decl.pos, types.Dfn, nil)
					d.sym = decl.left.right.sym
					d.init = decl
					d.tparams = rty.right
					d.dot = btd
					d.link = btd.ty.methtmpl
					btd.ty.methtmpl = d
					break
				}
			}
			if decl.right != nil && decl.right.aux != nil {
				// a generic function with its body: a template every
				// importer instantiates for itself (iface.c)
				if decl.left.op == types.Omethod {
					error(decl.line, sys.sprint("generic method %s cannot be declared in an interface", decl.left.right.sym))
					break
				}
				if decl.aux == nil {
					error(decl.line, sys.sprint("generic function %s in an interface needs its body: it is instantiated in each importer", decl.left.sym))
					break
				}
				d := types.mkdecl(decl.line, decl.pos, types.Dfn, nil)
				d.sym = decl.left.sym
				d.init = decl
				d.tparams = decl.right.aux
				installmember(mod, d)
				break
			}
			if decl.aux != nil && decl.left.op != types.Omethod {
				// a plain function with its body: inline, instantiated
				// by each importer (iface.c).  a method with a body
				// takes the ordinary path below, which resolves its
				// receiver, and is marked inline there
				d := types.mkdecl(decl.line, decl.pos, types.Dfn, nil)
				d.sym = decl.left.sym
				d.init = decl
				d.inl = 1
				installmember(mod, d)
				break
			}
			rawfn = 1
			t := itype(decl.right, mod)
			rawfn = 0
			if decl.left.op == types.Omethod {
				recv := decl.left.left
				rt := itype(recv.right, mod)
				bt := rt
				if bt.kind == types.Tref {
					bt = bt.tof
				}
				if bt.kind != types.Tadt && rt.kind != types.Tref && bt.decl != nil && bt.decl.store == types.Dtype && bt.decl.dot == mod {
					bt.named = 1	// "type Color int" with methods (check.e's typedec)
				}
				if (bt.kind != types.Tadt && bt.named == 0) || bt.decl == nil {
					error(decl.line, "receiver type must be a struct, ref struct or named type declared in this interface")
					break
				}
				rd := types.mkdecl(recv.left.line, recv.left.pos, types.Darg, rt)
				rd.sym = recv.left.sym
				rd.implicit = 1
				rd.next = t.ids
				t.ids = rd
			}
			t.ok |= types.OKverify
			types.sizetype(t)
			for a := t.ids; a != nil; a = a.next {
				types.sizetype(a.ty)
			}
			types.sizetype(t.tof)
			d := types.mkdecl(decl.line, decl.pos, types.Dfn, t)
			d.offset = types.idoffsets(t.ids, types.MaxTemp, types.IBY2WD)
			if decl.aux != nil {
				// a method of a plain adt, with its body: inline, as a function with one is
				d.init = decl
				d.inl = 1
			}
			if decl.left.op == types.Omethod {
				bt := t.ids.ty
				if bt.kind == types.Tref {
					bt = bt.tof
				}
				d.sym = decl.left.right.sym
				installmember(mod, d)
				d.dot = bt.decl
				d.link = bt.meths
				bt.meths = d
			} else {
				d.sym = decl.left.sym
				installmember(mod, d)
			}
		case types.Oimport:
			break
		default:
			error(decl.line, sys.sprint("unsupported interface declaration %s", types.opname(decl.op)))
		}
		if n.op != types.Oseq {
			break
		}
	}
	for d := mod.ty.ids; d != nil; d = d.next {
		if d.ty != nil {
			types.sizetype(d.ty)
		}
	}
	for d := mod.ty.ids; d != nil; d = d.next {
		if d.ty != nil && (d.store == types.Dfn || d.store == types.Dtype || d.store == types.Dglobal) {
			types.teqclass(d.ty)
		}
	}
	types.sizetype(mod.ty)
	types.teqclass(mod.ty)
}

// the module's own interface, <module>.ei beside the source file or
// on the include path, or nil silently: see iface.c's readownface()
var ownpath string

func ownfacepath() string {
	return ownpath
}

func readownface(modname string, srcfile string) ref types.Decl {
	b := []byte(modname)
	for i := 0; i < len(b); i++ {
		if b[i] >= byte('A') && b[i] <= byte('Z') {
			b[i] = byte(int(b[i]) - int('A') + int('a'))
		}
	}
	name := string(b) + ".ei"
	sb := []byte(srcfile)
	slash := -1
	for i := 0; i < len(sb); i++ {
		if sb[i] == byte('/') {
			slash = i
		}
	}
	var path string
	if slash >= 0 {
		dir := string(sb[0:slash])
		if sb[0] == byte('/') {
			path = dir + "/" + name
		} else {
			path = "./" + dir + "/" + name
		}
	} else {
		path = "./" + name
	}
	if exists(path) != 0 {
		ownpath = path
		return readiface(path)
	}
	for l := incdirs; l != nil; l = tl(l) {
		d := hd(l)
		p := d + "/" + name
		if len(d) > 0 && d[0] != '/' && d[0] != '.' {
			p = "./" + p
		}
		if exists(p) != 0 {
			ownpath = p
			return readiface(p)
		}
	}
	return nil
}

func readiface(path string) ref types.Decl {
	for l := ifaces; l != nil; l = tl(l) {
		if hd(l).path == path {
			return hd(l).d
		}
	}
	opened := openiface(path)
	if opened == nil {
		sys.fprint(sys.fildes(2), "ember: can't open interface %s\n", path)
		nerrors++
		return nil
	}
	ic := ref Icache{path: path, d: nil}
	ifaces = ic :: ifaces
	savedinfile := infile
	infile = opened
	tree := parse.parse(opened)
	nerrors += parse.errors()
	if tree == nil || tree.op != types.Omodule {
		sys.fprint(sys.fildes(2), "ember: %s: expected module interface\n", opened)
		nerrors++
		infile = savedinfile
		return nil
	}
	mod := types.mkdecl(tree.line, tree.pos, types.Dtype, nil)
	mod.sym = tree.left.sym
	mod.ty = types.mktype(tree.line, tree.pos, types.Tmodule, nil, nil)
	mod.ty.decl = mod
	bindiface(mod, tree)
	ic.d = mod
	infile = savedinfile
	return mod
}
