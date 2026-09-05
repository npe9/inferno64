module Xref

import sys "sys"
import types "types"
import check "check"

// a port of ember/xref.c: "emberc -X file.e" prints every name the
// file declares and every use of one, with positions and types, as an
// editor (or a language server) would want them:
//
//	decl LINE:COL NAME KIND TYPE
//	use LINE:COL NAME DECLLINE:DECLCOL TYPE
//
// the tree has been checked, so a use carries the declaration the
// checker resolved it to.  a declaration that came from an imported
// module reads "Module:LINE:COL", since its line is a line of that
// interface file, not of this one.  names the compiler made for
// itself (they begin with a dot or a dollar) are left out.  positions
// are the line and the character within it, both counting from 1.

var impdecl ref types.Decl
var seen list ref types.Decl
var cus []ref check.Cuse	// uses of constant names, which the tree no longer holds
var ncus int
var out ref sys.FD	// where the dump goes: standard output unless setout() says otherwise

func usetypes(t Types) {
	types = t
}

func usecheck(c Check) {
	check = c
}

// setout(fd): write the dump to fd rather than to standard output,
// for a caller that wants to read it back (appl/ember/emberls.e)
func setout(fd ref sys.FD) {
	out = fd
}

func kindof(d ref types.Decl) string {
	match d.store {
	case types.Dtype:
		return "type"
	case types.Dfn:
		// a method's dot is its type's declaration; a module member's is the module
		if d.dot != nil && d.dot != impdecl && d.dot.store == types.Dtype && d.dot.ty != nil && (d.dot.ty.kind == types.Tadt || d.dot.ty.named != 0) {
			return "method"
		}
		return "func"
	case types.Dglobal:
		return "global"
	case types.Dlocal:
		return "local"
	case types.Darg:
		return "arg"
	case types.Dconst:
		return "const"
	case types.Dfield:
		return "field"
	case types.Dtag:
		return "tag"
	case types.Dimport:
		return "import"
	}
	return "name"
}

func hidden(s string) int {
	if len(s) == 0 {
		return 1
	}
	if s[0] == '.' || s[0] == '$' {
		return 1
	}
	return 0
}

// a method is named for its type, so two "name"s can be told apart
func fnname(d ref types.Decl) string {
	if d.dot != nil && d.dot != impdecl && d.dot.store == types.Dtype {
		return d.dot.sym + "." + d.sym
	}
	return d.sym
}

// where a declaration is: "line:col" in the file being compiled, and
// "Module:line:col" when it came from an interface, since the line
// numbers there are that file's own
func declat(d ref types.Decl) string {
	if d.dot != nil && d.dot != impdecl && d.dot.ty != nil && d.dot.ty.kind == types.Tmodule {
		return sys.sprint("%s:%d:%d", d.dot.sym, d.line, d.pos + 1)
	}
	return sys.sprint("%d:%d", d.line, d.pos + 1)
}

// where a use is: always in the file being compiled
func useat(n ref types.Node) string {
	return sys.sprint("%d:%d", n.line, n.pos + 1)
}

// a declaration is printed once, the first time a use resolves to it
func xdecl(d ref types.Decl) {
	if d == nil || hidden(d.sym) != 0 || d.line <= 0 {
		return
	}
	for l := seen; l != nil; l = tl(l) {
		if hd(l) == d {
			return
		}
	}
	seen = d :: seen
	sys.fprint(out, "decl %s %s %s %s\n", declat(d), d.sym, kindof(d), types.tprint(d.ty))
}

// the constant name folded away at this node's position, if any
func constuse(n ref types.Node) ref check.Cuse {
	for i := 0; i < ncus; i++ {
		if cus[i].line == n.line && cus[i].pos == n.pos {
			return cus[i]
		}
	}
	return nil
}

func xwalk(n ref types.Node) {
	if n == nil {
		return
	}
	if n.op == types.Oconst && n.line > 0 {
		cu := constuse(n)
		if cu != nil && hidden(cu.sym) == 0 {
			xdecl(cu.decl)
			sys.fprint(out, "use %s %s %s %s\n", useat(n), cu.sym, declat(cu.decl), types.tprint(cu.decl.ty))
		}
	}
	if n.op == types.Oname && n.decl != nil && hidden(n.sym) == 0 && n.line > 0 {
		// a type name used in a literal has no type of its own: name the type
		t := n.ty
		if t == nil {
			t = n.decl.ty
		}
		xdecl(n.decl)
		if n.decl.line > 0 {
			sys.fprint(out, "use %s %s %s %s\n", useat(n), n.sym, declat(n.decl), types.tprint(t))
		} else {
			sys.fprint(out, "use %s %s - %s\n", useat(n), n.sym, types.tprint(t))
		}
	}
	xwalk(n.left)
	xwalk(n.right)
	xwalk(n.aux)
}

func xref(tree ref types.Node, moduledecl ref types.Decl, fns []ref types.Decl, nfns int, consts []ref check.Cuse, nconsts int) {
	impdecl = moduledecl
	cus = consts
	ncus = nconsts
	seen = nil
	if out == nil {
		out = sys.fildes(1)
	}
	// the module's own declarations, in the order they were written
	for p := tree.right; p != nil; p = p.right {
		d := p
		if p.op == types.Oseq {
			d = p.left
		}
		match d.op {
		case types.Ofndecl:
			if d.left.op == types.Omethod {
				xdecl(check.lookup(d.left.right.sym))
			} else {
				xdecl(check.lookup(d.left.sym))
			}
		case types.Otypedecl, types.Ocondecl:
			xdecl(check.lookup(d.left.sym))
		}
		if p.op != types.Oseq {
			break
		}
	}
	// then every use, function body by function body
	for i := 0; i < nfns; i++ {
		if fns[i].init != nil && fns[i].init.aux != nil && hidden(fns[i].sym) == 0 {
			xdecl(fns[i])
			sys.fprint(out, "in %s\n", fnname(fns[i]))
			xwalk(fns[i].init.aux)
		}
	}
}
