module Check

import sys "sys"
import types "types"
import fold "fold"
import iface "iface"

func usetypes(t Types) {
	types = t
	fold.usetypes(t)
	iface.usetypes(t)
}

// a port of ember/check.c, function for function.  the C symbol
// table binds a name through its Sym; here a small hash of name to
// the current Decl does the same job, with the same old-binding
// chains on the Decls.  Src pairs are (line, pos); Long values are
// bigs; the fns[] array grows by copying.

const MaxScope = 64
const MaxTinstDepth = 16
const HashSize = 1024

var impdecl ref types.Decl
var fns []ref types.Decl
var nfns = 0
var entrydecl ref types.Decl
var imports list ref types.Decl
var moduledecls ref types.Decl
var modname = ""
var nildecl ref types.Decl

var scopes = [MaxScope]ref types.Decl
var scopeends = [MaxScope]ref types.Decl
var scope = 0
var curfn ref types.Decl
var curret ref types.Type
var curclosure ref types.Decl
var nclosures = 0
var tinstack = [MaxTinstDepth]ref types.Decl
var tinstdepth = 0
var infile = ""
var nerrors = 0

var tint ref types.Type
var tbig ref types.Type
var tbyte ref types.Type
var treal ref types.Type
var tstring ref types.Type
var tany ref types.Type
var tnone ref types.Type
var terror ref types.Type

// every module that loads iface.dis gets its own copy of its data, so
// the include path must be given to the checker's own instance
func addincpath(dir string) {
	iface.addincpath(dir)
}

func fnlist() []ref types.Decl {
	return fns
}

func nfnlist() int {
	return nfns
}

func moduledecl() ref types.Decl {
	return impdecl
}

func entry() ref types.Decl {
	return entrydecl
}

func importlist() list ref types.Decl {
	return imports
}

func moduledecllist() ref types.Decl {
	return moduledecls
}

func nildeclare() ref types.Decl {
	return nildecl
}

// ---- the symbol table: name -> current binding

type Bind struct {
	name string
	d ref types.Decl
	next ref Bind
}

var binds = [HashSize]ref Bind

func hashname(s string) int {
	h := 0
	for i := 0; i < len(s); i++ {
		h = h * 31 + s[i]
	}
	if h < 0 {
		h = -h
	}
	return h % HashSize
}

var inref = 0	// stype() is resolving the operand of a ref
var rawfn = 0	// the next Otfunc stype() sees is a declaration's own signature

func lookup(name string) ref types.Decl {
	for b := binds[hashname(name)]; b != nil; b = b.next {
		if b.name == name {
			return b.d
		}
	}
	return nil
}

func setbind(name string, d ref types.Decl) {
	h := hashname(name)
	for b := binds[h]; b != nil; b = b.next {
		if b.name == name {
			b.d = d
			return
		}
	}
	binds[h] = ref Bind{name: name, d: d, next: binds[h]}
}

func error(line int, msg string) {
	nerrors++
	sys.fprint(sys.fildes(2), "%s:%d: %s\n", infile, line, msg)
}

func fatal(msg string) {
	sys.fprint(sys.fildes(2), "fatal ember compiler error: %s\n", msg)
	var l list int
	hd(l)
}

// a diagnostic about a line of another file (the module's own interface)
func errorat(file string, line int, msg string) {
	nerrors++
	sys.fprint(sys.fildes(2), "%s:%d: %s\n", file, line, msg)
}

func nerror(n ref types.Node, msg string) {
	error(n.line, msg)
}

func tp(t ref types.Type) string {
	return types.tprint(t)
}

func pushscope() {
	if scope >= MaxScope - 1 {
		error(0, "fatal: scopes too deep")
		return
	}
	scope++
	scopes[scope] = nil
	scopeends[scope] = nil
}

func popscope() ref types.Decl {
	for d := scopes[scope]; d != nil; d = d.next {
		if d.sym != nil && lookup(d.sym) == d {
			setbind(d.sym, d.old)
		}
	}
	s := scopes[scope]
	scope--
	return s
}

func installids(ids ref types.Decl) {
	var last ref types.Decl
	for d := ids; d != nil; d = d.next {
		d.scope = scope
		if d.sym != nil {
			d.old = lookup(d.sym)
			setbind(d.sym, d)
		}
		last = d
	}
	if ids != nil {
		if scopes[scope] == nil {
			scopes[scope] = ids
		} else {
			scopeends[scope].next = ids
		}
		scopeends[scope] = last
	}
}

func install(d ref types.Decl) {
	d.next = nil
	installids(d)
}

func addfn(d ref types.Decl) {
	if fns == nil || nfns >= len(fns) {
		nf := [nfns + 32]ref types.Decl
		for i := 0; i < nfns; i++ {
			nf[i] = fns[i]
		}
		fns = nf
	}
	fns[nfns] = d
	nfns++
}

func declbuiltin(name string, t ref types.Type) {
	d := types.mkdecl(0, 0, types.Dtype, t)
	d.sym = name
	install(d)
	if t.decl == nil {
		t.decl = d
	}
}

// node helpers, ast.c's
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

func dupntree(n ref types.Node) ref types.Node {
	if n == nil {
		return nil
	}
	m := types.dupn(n)
	m.left = dupntree(n.left)
	m.right = dupntree(n.right)
	m.aux = dupntree(n.aux)
	return m
}

func seqcount(p ref types.Node) int {
	n := 0
	for ; p != nil; p = p.right {
		n++
		if p.op != types.Oseq {
			break
		}
	}
	return n
}

func seqitem(p ref types.Node) ref types.Node {
	if p.op == types.Oseq {
		return p.left
	}
	return p
}

func instname(base string, argv []ref types.Type, nargs int) string {
	s := base + "["
	for i := 0; i < nargs; i++ {
		if i > 0 {
			s += ", "
		}
		s += tp(argv[i])
	}
	return s + "]"
}

// ---- generics

func tinstantiate(n ref types.Node) ref types.Type {
	if n.left.op != types.Oname {
		nerror(n, "bad generic type reference")
		return terror
	}
	td := lookup(n.left.sym)
	if td == nil || td.store != types.Dtype {
		nerror(n, sys.sprint("%s is not a type", n.left.sym))
		return terror
	}
	n.left.decl = td
	tt := td.ty
	if tt == nil || tt.tparams == nil {
		nerror(n, sys.sprint("%s is not a generic type", tp(tt)))
		return terror
	}
	nargs := seqcount(n.right)
	argv := [nargs]ref types.Type
	i := 0
	for p := n.right; p != nil; p = p.right {
		argv[i] = stype(seqitem(p))
		i++
		if p.op != types.Oseq {
			break
		}
	}
	nparams := seqcount(tt.tparams)
	if nargs != nparams {
		plural := "s"
		if nparams == 1 {
			plural = ""
		}
		nerror(n, sys.sprint("%s needs %d type argument%s, got %d", td.sym, nparams, plural, nargs))
		return terror
	}
	for ti := tt.tinsts; ti != nil; ti = ti.next {
		m := 1
		for i = 0; i < nargs; i++ {
			if ti.args[i] != argv[i] {
				m = 0
				break
			}
		}
		if m != 0 {
			return ti.ty
		}
	}
	// a struct instance is a placeholder, cached before its body is
	// walked, so a self-referencing field finds it (check.c)
	var inst ref types.Type
	var ti ref types.Ginst
	if tt.tbody != nil && tt.tbody.op == types.Otstruct {
		inst = types.mktype(n.line, n.pos, types.Tadt, nil, nil)
		ti = ref types.Ginst{nargs: nargs, args: argv, ty: inst, decl: nil, next: tt.tinsts}
		tt.tinsts = ti
	} else {
		for i = 0; i < tinstdepth; i++ {
			if tinstack[i] == td {
				nerror(n, sys.sprint("%s: recursive generic instantiation not yet supported", td.sym))
				return terror
			}
		}
	}
	if tinstdepth >= MaxTinstDepth {
		nerror(n, "generic types nested too deeply")
		return terror
	}
	tinstack[tinstdepth] = td
	tinstdepth++
	pushscope()
	i = 0
	for p := tt.tparams; p != nil; p = p.right {
		pn := seqitem(p)
		pd := types.mkdecl(pn.line, pn.pos, types.Dtype, argv[i])
		pd.sym = pn.sym
		install(pd)
		i++
		if p.op != types.Oseq {
			break
		}
	}
	body := stype(tt.tbody)
	popscope()
	tinstdepth--
	if inst != nil {
		if body == terror {
			return terror
		}
		types.copytype(inst, body)
	} else {
		inst = body
	}
	id := types.mkdecl(n.line, n.pos, types.Dtype, inst)
	id.sym = instname(td.sym, argv, nargs)
	inst.decl = id
	types.sizetype(inst)
	types.teqclass(inst)
	if ti == nil {
		ti = ref types.Ginst{nargs: nargs, args: argv, ty: inst, decl: nil, next: tt.tinsts}
		tt.tinsts = ti
	}
	inst.gtemplate = tt
	inst.ginst = ti
	return inst
}

func tinstantiatefncore(line int, pos int, td ref types.Decl, argv []ref types.Type, nargs int, recvarg ref types.Decl) ref types.Decl {
	for fi := td.finsts; fi != nil; fi = fi.next {
		m := 1
		for i := 0; i < nargs; i++ {
			if fi.args[i] != argv[i] {
				m = 0
				break
			}
		}
		if m != 0 {
			return fi.decl
		}
	}
	if tinstdepth >= MaxTinstDepth {
		error(line, "generic functions nested too deeply")
		return nil
	}
	tinstack[tinstdepth] = td
	tinstdepth++
	pushscope()
	i := 0
	for p := td.tparams; p != nil; p = p.right {
		pn := seqitem(p)
		pd := types.mkdecl(pn.line, pn.pos, types.Dtype, argv[i])
		pd.sym = pn.sym
		install(pd)
		i++
		if p.op != types.Oseq {
			break
		}
	}
	tn := dupntree(td.init)
	rawfn = 1
	ft := stype(tn.right)
	rawfn = 0
	if recvarg != nil {
		recvarg.next = ft.ids
		ft.ids = recvarg
	}
	ft.ok |= types.OKverify
	types.sizetype(ft)
	for dd := ft.ids; dd != nil; dd = dd.next {
		types.sizetype(dd.ty)
	}
	types.sizetype(ft.tof)
	fnd := types.mkdecl(line, pos, types.Dfn, ft)
	fnd.sym = instname(td.sym, argv, nargs)
	fnd.init = tn
	fnd.offset = types.idoffsets(ft.ids, types.MaxTemp, types.IBY2WD)
	fnd.dot = impdecl
	addfn(fnd)
	// cached before its body is checked, for a recursive call (check.c)
	fi := ref types.Ginst{nargs: nargs, args: argv, ty: nil, decl: fnd, next: td.finsts}
	td.finsts = fi
	savedcurfn := curfn
	savedcurret := curret
	fnchk(fnd)
	curfn = savedcurfn
	curret = savedcurret
	fnd.checked = 1
	popscope()
	tinstdepth--
	return fnd
}

// the env-prepended calling convention every function value uses
func wrapbody(line int, pos int, call ref types.Node, isvoid int) ref types.Node {
	if isvoid != 0 {
		stmts := types.mkseq(nil, types.mkn(types.Oexpr, call, nil))
		stmts = types.mkseq(stmts, types.mkn(types.Oret, nil, nil))
		return types.mkn(types.Oscope, types.rotater(stmts), nil)
	}
	stmt := types.mkn(types.Oret, call, nil)
	return types.mkn(types.Oscope, stmt, nil)
}

func synthfvwrap(line int, pos int, fn ref types.Decl) ref types.Decl {
	if fn.wrapdecl != nil {
		return fn.wrapdecl
	}
	wt := types.envfn(line, pos, fn.ty)
	fn.valty = types.mktype(line, pos, types.Tref, wt, nil)
	types.sizetype(fn.valty)
	wd := types.mkdecl(line, pos, types.Dfn, wt)
	wd.sym = fn.sym + "$fv"
	wd.dot = impdecl
	wd.offset = types.idoffsets(wt.ids, types.MaxTemp, types.IBY2WD)
	call := mkname(line, pos, fn.sym)
	var args ref types.Node
	for arg := wt.ids.next; arg != nil; arg = arg.next {
		args = types.mkseq(args, mkname(line, pos, arg.sym))
	}
	call = types.mkn(types.Ocall, call, types.rotater(args))
	isvoid := 0
	if fn.ty.tof == tnone {
		isvoid = 1
	}
	wd.init = types.mkn(types.Ofndecl, nil, nil)
	wd.init.aux = wrapbody(line, pos, call, isvoid)
	addfn(wd)
	savedcurfn := curfn
	savedcurret := curret
	fnchk(wd)
	curfn = savedcurfn
	curret = savedcurret
	wd.checked = 1
	fn.wrapdecl = wd
	return wd
}

func synthimportwrap(line int, pos int, alias ref types.Decl, id ref types.Decl) ref types.Decl {
	if id.ty.varargs != 0 {
		error(line, sys.sprint("%s.%s takes a variable number of arguments and cannot be used as a value", alias.sym, id.sym))
		return nil
	}
	wsym := alias.sym + "." + id.sym + "$fv"
	wd := lookup(wsym)
	if wd != nil {
		return wd
	}
	wt := types.envfn(line, pos, id.ty)
	wd = types.mkdecl(line, pos, types.Dfn, wt)
	wd.sym = wsym
	wd.dot = impdecl
	wd.offset = types.idoffsets(wt.ids, types.MaxTemp, types.IBY2WD)
	dot := types.mkbin(types.Odot, mkname(line, pos, alias.sym), mkname(line, pos, id.sym))
	dot.sym = id.sym
	var args ref types.Node
	for arg := wt.ids.next; arg != nil; arg = arg.next {
		args = types.mkseq(args, mkname(line, pos, arg.sym))
	}
	call := types.mkn(types.Ocall, dot, types.rotater(args))
	isvoid := 0
	if id.ty.tof == tnone {
		isvoid = 1
	}
	wd.init = types.mkn(types.Ofndecl, nil, nil)
	wd.init.aux = wrapbody(line, pos, call, isvoid)
	addfn(wd)
	install(wd)
	savedcurfn := curfn
	savedcurret := curret
	fnchk(wd)
	curfn = savedcurfn
	curret = savedcurret
	wd.checked = 1
	wd.valty = types.mktype(line, pos, types.Tref, wt, nil)
	types.sizetype(wd.valty)
	wd.wrapdecl = wd
	return wd
}

func declownedby(d ref types.Decl, fn ref types.Decl) int {
	for p := fn.ty.ids; p != nil; p = p.next {
		if p == d {
			return 1
		}
	}
	for p := fn.locals; p != nil; p = p.link {
		if p == d {
			return 1
		}
	}
	return 0
}

func addcapture(closure ref types.Decl, orig ref types.Decl, n ref types.Node) {
	found := 0
	for l := closure.captures; l != nil; l = tl(l) {
		if hd(l) == orig {
			found = 1
			break
		}
	}
	if found == 0 {
		closure.captures = orig :: closure.captures
	}
	if n == nil {
		return
	}
	if closure.capuses == nil || closure.ncapuses >= len(closure.capuses) {
		nc := [closure.ncapuses + 32]ref types.Node
		for i := 0; i < closure.ncapuses; i++ {
			nc[i] = closure.capuses[i]
		}
		closure.capuses = nc
	}
	closure.capuses[closure.ncapuses] = n
	closure.ncapuses++
}

func synthfunclit(n ref types.Node) ref types.Decl {
	rawfn = 1
	pubt := stype(n.right)
	rawfn = 0
	wt := types.envfn(n.line, n.pos, pubt)
	ld := types.mkdecl(n.line, n.pos, types.Dfn, wt)
	ld.sym = sys.sprint("$closure%d", nclosures)
	nclosures++
	ld.dot = impdecl
	ld.offset = types.idoffsets(wt.ids, types.MaxTemp, types.IBY2WD)
	ld.init = types.mkn(types.Ofndecl, nil, nil)
	ld.init.aux = n.aux
	ld.wrapdecl = ld
	addfn(ld)
	ld.enclosing = curfn
	savedcurfn := curfn
	savedcurret := curret
	savedclosure := curclosure
	curclosure = ld
	fnchk(ld)
	curclosure = savedclosure
	curfn = savedcurfn
	curret = savedcurret
	ld.checked = 1
	if ld.captures != nil {
		// captures were prepended: the C list is in reverse order of
		// discovery too (each new capture goes at the head)
		var fids ref types.Decl
		var flast ref types.Decl
		i := 0
		for cl := ld.captures; cl != nil; cl = tl(cl) {
			fd := types.mkdecl(n.line, n.pos, types.Dfield, hd(cl).ty)
			fd.sym = sys.sprint(".cap%d", i)
			i++
			if fids == nil {
				fids = fd
			} else {
				flast.next = fd
			}
			flast = fd
		}
		ld.capty = types.mktype(n.line, n.pos, types.Tadt, nil, fids)
		ld.capty.ok |= types.OKverify
		tdecl := types.mkdecl(n.line, n.pos, types.Dtype, ld.capty)
		tdecl.sym = ld.sym + "$env"
		ld.capty.decl = tdecl
		types.sizetype(ld.capty)
		for fd := ld.capty.ids; fd != nil; fd = fd.next {
			types.sizetype(fd.ty)
		}
		for i = 0; i < ld.ncapuses; i++ {
			un := ld.capuses[i]
			pos := 0
			for cl2 := ld.captures; cl2 != nil; cl2 = tl(cl2) {
				if hd(cl2) == un.decl {
					break
				}
				pos++
			}
			fd := ld.capty.ids
			for pos > 0 {
				fd = fd.next
				pos--
			}
			envref := mkname(un.line, un.pos, ld.ty.ids.sym)
			envref.decl = ld.ty.ids
			envrefty := types.mktype(un.line, un.pos, types.Tref, ld.capty, nil)
			types.sizetype(envrefty)
			envref.ty = envrefty
			off := mkconst(un.line, un.pos, big(fd.offset))
			off.ty = tint
			addr := types.mkn(types.Oadd, envref, off)
			addr.line = un.line
			addr.pos = un.pos
			addr.ty = tint
			un.op = types.Oind
			un.left = addr
			un.right = nil
			un.decl = fd
			un.ty = fd.ty
		}
	}
	return ld
}

func tinstantiatefn(n ref types.Node) ref types.Decl {
	if n.left.op != types.Oname {
		nerror(n, "bad generic function reference")
		return nil
	}
	td := lookup(n.left.sym)
	if td == nil || td.store != types.Dfn || td.tparams == nil {
		nerror(n, sys.sprint("%s is not a generic function", n.left.sym))
		return nil
	}
	n.left.decl = td
	nargs := seqcount(n.right)
	argv := [nargs]ref types.Type
	i := 0
	for p := n.right; p != nil; p = p.right {
		argv[i] = stype(seqitem(p))
		i++
		if p.op != types.Oseq {
			break
		}
	}
	nparams := seqcount(td.tparams)
	if nargs != nparams {
		plural := "s"
		if nparams == 1 {
			plural = ""
		}
		nerror(n, sys.sprint("%s needs %d type argument%s, got %d", td.sym, nparams, plural, nargs))
		return nil
	}
	return tinstantiatefncore(n.line, n.pos, td, argv, nargs, nil)
}

func unifytparam(pt ref types.Node, at ref types.Type, tparams ref types.Node, argv []ref types.Type) {
	if pt == nil || at == nil || at == terror {
		return
	}
	match pt.op {
	case types.Oname:
		j := 0
		for tpn := tparams; tpn != nil; tpn = tpn.right {
			t := seqitem(tpn)
			if t.sym == pt.sym {
				if argv[j] == nil {
					argv[j] = at
				}
				return
			}
			j++
			if tpn.op != types.Oseq {
				break
			}
		}
		return
	case types.Otarray:
		if at.kind != types.Tarray {
			return
		}
		unifytparam(pt.right, at.tof, tparams, argv)
	case types.Otchan:
		if at.kind != types.Tchan {
			return
		}
		unifytparam(pt.right, at.tof, tparams, argv)
	case types.Otlist:
		if at.kind != types.Tlist {
			return
		}
		unifytparam(pt.right, at.tof, tparams, argv)
	case types.Otref:
		if at.kind != types.Tref {
			return
		}
		unifytparam(pt.right, at.tof, tparams, argv)
	case types.Otinst:
		if pt.left == nil || pt.left.op != types.Oname {
			return
		}
		if at.kind != types.Tadt || at.gtemplate == nil || at.ginst == nil {
			return
		}
		itd := lookup(pt.left.sym)
		if itd == nil || itd.store != types.Dtype || itd.ty != at.gtemplate {
			return
		}
		ta := pt.right
		i := 0
		for ta != nil && i < at.ginst.nargs {
			unifytparam(seqitem(ta), at.ginst.args[i], tparams, argv)
			i++
			if ta.op != types.Oseq {
				break
			}
			ta = ta.right
		}
	case types.Ottuple:
		if at.kind != types.Ttuple {
			return
		}
		pd := at.ids
		for ta := pt.left; ta != nil && pd != nil; ta = ta.right {
			unifytparam(seqitem(ta), pd.ty, tparams, argv)
			pd = pd.next
			if ta.op != types.Oseq {
				break
			}
		}
	case types.Otfunc:
		if at.kind != types.Tref || at.tof == nil || at.tof.kind != types.Tfn {
			return
		}
		ft := at.tof
		pd := ft.ids
		if ft.hasenv != 0 && pd != nil {
			pd = pd.next
		}
		for pp := pt.left; pp != nil && pd != nil; pp = pp.right {
			pf := seqitem(pp)
			if pf.left == nil {
				unifytparam(pf.right, pd.ty, tparams, argv)
				pd = pd.next
			} else {
				for pids := pf.left; pids != nil && pd != nil; pids = pids.right {
					unifytparam(pf.right, pd.ty, tparams, argv)
					pd = pd.next
					if pids.op != types.Oseq {
						break
					}
				}
			}
			if pp.op != types.Oseq {
				break
			}
		}
		if pt.right != nil {
			unifytparam(pt.right, ft.tof, tparams, argv)
		}
	}
}

func inferfn(n ref types.Node) ref types.Decl {
	if n.left.op != types.Oname {
		return nil
	}
	td := lookup(n.left.sym)
	if td == nil || td.store != types.Dfn || td.tparams == nil {
		return nil
	}
	n.left.decl = td
	nparams := seqcount(td.tparams)
	argv := [nparams]ref types.Type
	a := n.right
	for p := td.init.right.left; p != nil && a != nil; p = p.right {
		f := seqitem(p)
		for ids := f.left; ids != nil && a != nil; ids = ids.right {
			arg := seqitem(a)
			unifytparam(f.right, echk(arg), td.tparams, argv)
			if a.op == types.Oseq {
				a = a.right
			} else {
				a = nil
			}
			if ids.op != types.Oseq {
				break
			}
		}
		if p.op != types.Oseq {
			break
		}
	}
	for i := 0; i < nparams; i++ {
		if argv[i] == nil {
			nerror(n, sys.sprint("cannot infer all type arguments for %s; use %s[...] explicitly", td.sym, td.sym))
			return nil
		}
	}
	return tinstantiatefncore(n.line, n.pos, td, argv, nparams, nil)
}

func tinstantiatemeth(mtd ref types.Decl, t ref types.Type) ref types.Decl {
	recv := mtd.init.left.left
	rt := t
	if recv.right.op == types.Otref {
		rt = types.mktype(mtd.line, mtd.pos, types.Tref, t, nil)
	}
	rd := types.mkdecl(recv.left.line, recv.left.pos, types.Darg, rt)
	rd.sym = recv.left.sym
	rd.implicit = 1
	return tinstantiatefncore(mtd.line, mtd.pos, mtd, t.ginst.args, t.ginst.nargs, rd)
}

// ---- type expressions

func stype(n ref types.Node) ref types.Type {
	if n == nil {
		return tnone
	}
	match n.op {
	case types.Otarray:
		return types.mktype(n.line, n.pos, types.Tarray, stype(n.right), nil)
	case types.Otchan:
		return types.mktype(n.line, n.pos, types.Tchan, stype(n.right), nil)
	case types.Otlist:
		return types.mktype(n.line, n.pos, types.Tlist, stype(n.right), nil)
	case types.Oref:
		// "ref P" parsed as an expression: the type form (check.c)
		n.op = types.Otref
		n.right = n.left
		n.left = nil
		return stype(n)
	case types.Otref:
		inref++
		t := stype(n.right)
		inref--
		if t.kind != types.Tadt && t.kind != types.Tfn && t.kind != types.Tadtpick && t.kind != types.Terror && t.kind != types.Tpoly {
			nerror(n, "ref requires an adt or function type")
			return terror
		}
		return types.mktype(n.line, n.pos, types.Tref, t, nil)
	case types.Otstruct:
		t := types.mktype(n.line, n.pos, types.Tadt, nil, nil)
		var ids ref types.Decl
		var last ref types.Decl
		for p := n.left; p != nil; p = p.right {
			f := seqitem(p)
			for names := f.left; names != nil; names = names.right {
				id := seqitem(names)
				d := types.mkdecl(id.line, id.pos, types.Dfield, stype(f.right))
				d.sym = id.sym
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
			if p.op != types.Oseq {
				break
			}
		}
		t.ids = ids
		t.ok |= types.OKverify
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
			tn := seqitem(p)
			d := types.mkdecl(tn.line, tn.pos, types.Dfield, stype(tn))
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
		// a function type is a closure value everywhere but in a
		// declaration's own signature (check.c)
		raw := rawfn
		rawfn = 0
		var args ref types.Decl
		var last ref types.Decl
		ft := types.mktype(n.line, n.pos, types.Tfn, tnone, nil)
		for p := n.left; p != nil; p = p.right {
			f := seqitem(p)
			if f.op != types.Ofield {
				nerror(f, "bad param node in stype")
				break
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
			t := stype(f.right)
			if t.kind == types.Tfn {
				t = types.mktype(f.line, f.pos, types.Tref, types.envfn(f.line, f.pos, t), nil)
			}
			if f.left == nil {
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
					id := seqitem(ids)
					d := types.mkdecl(id.line, id.pos, types.Darg, t)
					d.sym = id.sym
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
			ft.tof = stype(n.right)
			if ft.tof.kind == types.Tfn {
				ft.tof = types.mktype(n.line, n.pos, types.Tref, types.envfn(n.line, n.pos, ft.tof), nil)
			}
		}
		if raw != 0 {
			return ft
		}
		return types.mktype(n.line, n.pos, types.Tref, types.envfn(n.line, n.pos, ft), nil)
	case types.Oname:
		d := lookup(n.sym)
		if d == nil || d.store != types.Dtype {
			nerror(n, sys.sprint("%s is not a type", n.sym))
			return terror
		}
		if d.ty != nil && d.ty.tparams != nil {
			nerror(n, sys.sprint("%s needs type arguments, e.g. %s[...]", n.sym, n.sym))
			return terror
		}
		// a pick exists only behind a ref (check.c)
		if inref == 0 && d.ty != nil && d.ty.kind == types.Tadt && d.ty.tags != nil {
			nerror(n, sys.sprint("pick %s has no size of its own: use ref %s", n.sym, n.sym))
			return terror
		}
		n.decl = d
		return d.ty
	case types.Otinst, types.Oindex:
		return tinstantiate(n)
	case types.Odot:
		rt := terror
		if n.left.op == types.Odot {
			at := stype(n.left)
			if at != terror {
				if at.kind != types.Tadt || at.tags == nil {
					nerror(n, sys.sprint("%s is not a pick type", tp(at)))
				} else {
					for tg := at.tags; tg != nil; tg = tg.next {
						if tg.sym == n.sym {
							rt = tg.ty
							break
						}
					}
					if rt == terror {
						nerror(n, sys.sprint("%s has no tag %s", tp(at), n.sym))
					}
				}
			}
			n.left = nil
			n.right = nil
			return rt
		}
		if n.left.op != types.Oname {
			nerror(n, "bad qualified type")
			return terror
		}
		md := lookup(n.left.sym)
		if md != nil && md.store == types.Dtype && md.ty != nil && md.ty.kind == types.Tadt && md.ty.tags != nil {
			for tg := md.ty.tags; tg != nil; tg = tg.next {
				if tg.sym == n.sym {
					rt = tg.ty
					break
				}
			}
			if rt == terror {
				nerror(n, sys.sprint("%s has no tag %s", tp(md.ty), n.sym))
			}
		} else if md == nil || md.ty == nil || md.ty.kind != types.Tmodule {
			nerror(n, sys.sprint("%s is not a module", n.left.sym))
		} else {
			for id := md.ty.ids; id != nil; id = id.next {
				if id.sym == n.sym && id.store == types.Dtype {
					rt = id.ty
					break
				}
			}
			if rt == terror {
				nerror(n, sys.sprint("%s has no type %s", n.left.sym, n.sym))
			}
		}
		n.left = nil
		n.right = nil
		return rt
	}
	nerror(n, sys.sprint("unsupported type expression %s", types.opname(n.op)))
	return terror
}

func assignable(t ref types.Type, s ref types.Type, v ref types.Node) int {
	if t == nil || s == nil {
		return 0
	}
	if s == tany || (v != nil && v.op == types.Onil) {
		if types.isptr(t.kind) != 0 {
			if v != nil {
				v.ty = t
			}
			return 1
		}
		return 0
	}
	if t == tany {
		return types.isptr(s.kind)
	}
	if t.kind == types.Tref && s.kind == types.Tref && s.tof != nil && s.tof.kind == types.Tadtpick && t.tof != nil && t.tof.kind == types.Tadt && t.tof.tags != nil && s.tof.tof == t.tof {
		return 1
	}
	return types.tequal(t, s)
}

func confold(n ref types.Node, d ref types.Decl) int {
	i := d.init
	if i == nil || i.op != types.Oconst {
		return 0
	}
	n.op = types.Oconst
	n.left = nil
	n.right = nil
	n.aux = nil
	n.flags = i.flags
	n.val = i.val
	n.rval = i.rval
	n.sym = i.sym
	n.ty = i.ty
	n.decl = nil
	return 1
}

func importchk(n ref types.Node) {
	m := iface.readiface(n.right.sym)
	if m == nil {
		nerrors++
		return
	}
	name := m.sym
	if n.left != nil {
		name = n.left.sym
	}
	v := types.mkdecl(n.line, n.pos, types.Dglobal, m.ty)
	v.sym = name
	v.importid = m
	install(v)
	n.decl = v
	imports = v :: imports
	if lookup(m.sym) == nil {
		install(m)
	}
}

func modmember(mt ref types.Type, s string) ref types.Decl {
	for id := mt.ids; id != nil; id = id.next {
		if id.store == types.Dfn && id.dot != nil && id.dot.ty != nil && id.dot.ty.kind == types.Tadt {
			continue
		}
		if id.sym == s {
			return id
		}
	}
	return nil
}

func methodmodule(meth ref types.Decl) ref types.Decl {
	td := meth.dot
	if td == nil || td.store != types.Dtype || td.ty == nil || td.ty.kind != types.Tadt || td.dot == nil || td.dot == impdecl {
		return nil
	}
	for l := imports; l != nil; l = tl(l) {
		if hd(l).importid == td.dot {
			return hd(l)
		}
	}
	return nil
}

func ismodvar(d ref types.Decl) int {
	return d.store == types.Dglobal || d.store == types.Dlocal || d.store == types.Darg
}

func modcallee(dot ref types.Node) ref types.Decl {
	if dot.op != types.Odot || dot.left.op != types.Oname {
		return nil
	}
	alias := lookup(dot.left.sym)
	if alias == nil || alias.ty == nil || alias.ty.kind != types.Tmodule || ismodvar(alias) == 0 {
		return nil
	}
	id := modmember(alias.ty, dot.sym)
	if id == nil || id.store != types.Dfn {
		return nil
	}
	return id
}

func compositefields(n ref types.Node) ref types.Type {
	t := stype(n.left)
	if t.kind != types.Tadt && t.kind != types.Tadtpick {
		nerror(n, sys.sprint("composite literal of non-struct type %s", tp(t)))
		n.ty = terror
		return n.ty
	}
	if t.kind == types.Tadt && t.tags != nil {
		nerror(n, sys.sprint("composite literal of tagged type %s not yet supported -- construct a specific tag instead, e.g. %s.Tag{...}", tp(t), tp(t)))
		n.ty = terror
		return n.ty
	}
	var shared ref types.Decl
	if t.kind == types.Tadtpick {
		shared = t.tof.ids
	}
	keyed := -1
	fid := t.ids
	switched := 0
	if shared == nil {
		switched = 1
	}
	for p := n.right; p != nil; p = p.right {
		e := seqitem(p)
		var fd ref types.Decl
		if e.left != nil {
			if keyed == 0 {
				nerror(e, sys.sprint("cannot mix keyed and positional elements in %s composite literal", tp(t)))
			}
			keyed = 1
			for fd = t.ids; fd != nil; fd = fd.next {
				if fd.sym == e.left.sym {
					break
				}
			}
			if fd == nil {
				for fd = shared; fd != nil; fd = fd.next {
					if fd.sym == e.left.sym {
						break
					}
				}
			}
			if fd == nil {
				nerror(e, sys.sprint("%s has no field %s", tp(t), e.left.sym))
			}
		} else {
			if keyed == 1 {
				nerror(e, sys.sprint("cannot mix keyed and positional elements in %s composite literal", tp(t)))
			}
			keyed = 0
			if fid == nil && switched == 0 {
				fid = shared
				switched = 1
			}
			fd = fid
			if fd == nil {
				nerror(e, sys.sprint("too many elements in %s composite literal", tp(t)))
			} else {
				fid = fid.next
			}
		}
		if fd != nil && fd.ty.kind == types.Tadtpick {
			nerror(e, sys.sprint("composite literal field %s: tagged fields not yet supported", fd.sym))
			fd = nil
		}
		var vt ref types.Type
		if e.right.op == types.Ocomposite {
			vt = compositefields(e.right)
		} else {
			vt = echk(e.right)
		}
		if fd != nil {
			fty := fd.ty
			if assignable(fty, vt, e.right) == 0 {
				nerror(e, sys.sprint("cannot use %s as %s for field %s in composite literal", tp(vt), tp(fty), fd.sym))
			}
			e.decl = fd
		}
		e.left = nil
		if p.op != types.Oseq {
			break
		}
	}
	if keyed == 0 {
		if fid == nil && switched == 0 {
			fid = shared
		}
		if fid != nil {
			nerror(n, sys.sprint("too few elements in %s composite literal", tp(t)))
		}
	}
	n.ty = t
	return n.ty
}

func retypetuple(e ref types.Node, want ref types.Type) {
	if e == nil || e.op != types.Otuple || e.ty == nil || e.ty.kind != types.Ttuple || want == nil || want.kind != types.Ttuple {
		return
	}
	fd := want.ids
	td := e.ty.ids
	for p := e.left; p != nil && fd != nil && td != nil; p = p.right {
		c := seqitem(p)
		if c.ty == tany && assignable(fd.ty, c.ty, c) != 0 {
			c.ty = fd.ty
			td.ty = fd.ty
		}
		fd = fd.next
		td = td.next
		if p.op != types.Oseq {
			break
		}
	}
	e.ty.ok &= ~types.OKsized
	e.ty.size = 0
	types.sizetype(e.ty)
}

// ---- expressions

func echk(n ref types.Node) ref types.Type {
	if n == nil {
		return tnone
	}
	if (n.flags & types.NCHECKED) != 0 {
		return n.ty
	}
	t := echk1(n)
	if n.ty == nil {
		n.ty = t
	}
	n.flags |= types.NCHECKED
	return t
}

func mkidname(line int, pos int, d ref types.Decl) ref types.Node {
	m := types.mkn(types.Oname, nil, nil)
	m.line = line
	m.pos = pos
	m.sym = d.sym
	m.decl = d
	m.ty = d.ty
	return m
}

func isnum(t ref types.Type) int {
	return t.kind == types.Tint || t.kind == types.Tbig || t.kind == types.Treal || t.kind == types.Tbyte
}

func echk1(n ref types.Node) ref types.Type {
	match n.op {
	case types.Oconst:
		if (n.flags & types.NSTR) != 0 {
			n.ty = tstring
		} else if (n.flags & types.NREAL) != 0 {
			n.ty = treal
		} else if n.ty == tbig {
			return n.ty
		} else if n.val > big(2147483647) || n.val < big(-2147483647) - big(1) {
			n.ty = tbig
		} else {
			n.ty = tint
		}
		return n.ty
	case types.Onil:
		n.ty = tany
		return n.ty
	case types.Oname:
		d := lookup(n.sym)
		if d == nil {
			nerror(n, sys.sprint("%s is not declared", n.sym))
			n.ty = terror
			return n.ty
		}
		if d.store == types.Dconst {
			if confold(n, d) != 0 {
				return n.ty
			}
			nerror(n, sys.sprint("constant %s is not usable here", n.sym))
			n.ty = terror
			return n.ty
		}
		d.refs++
		n.decl = d
		n.ty = d.ty
		if curclosure != nil && (d.store == types.Darg || d.store == types.Dlocal) && declownedby(d, curclosure) == 0 {
			anc := curclosure.enclosing
			for anc != nil && declownedby(d, anc) == 0 {
				anc = anc.enclosing
			}
			if anc == nil {
				nerror(n, sys.sprint("cannot resolve capture of %s", n.sym))
				n.ty = terror
				return n.ty
			}
			for cl := curclosure; cl.enclosing != anc; cl = cl.enclosing {
				addcapture(cl.enclosing, d, nil)
			}
			addcapture(curclosure, d, n)
		}
		if d.store == types.Dfn && d.ty != nil {
			if synthfvwrap(n.line, n.pos, d) == nil {
				n.ty = terror
				return n.ty
			}
			n.ty = d.valty
		}
		return n.ty
	case types.Odot:
		return chkdot(n)
	case types.Ocall:
		return chkcall(n)
	case types.Oadd, types.Osub, types.Omul, types.Odiv, types.Omod, types.Oand, types.Oor, types.Oxor, types.Olsh, types.Orsh:
		t := echk(n.left)
		tr := echk(n.right)
		if t == terror || tr == terror {
			n.ty = terror
			return n.ty
		}
		if (n.op == types.Olsh || n.op == types.Orsh) && tr == tint && (t.kind == types.Tbig || t.kind == types.Tbyte) {
			tr = t
		}
		if types.tequal(t, tr) == 0 {
			nerror(n, sys.sprint("type mismatch: %s %s %s", tp(t), types.opname(n.op), tp(tr)))
			n.ty = terror
			return n.ty
		}
		match t.kind {
		case types.Tint, types.Tbig, types.Tbyte:
			break
		case types.Treal:
			if n.op == types.Omod || n.op == types.Oand || n.op == types.Oor || n.op == types.Oxor || n.op == types.Olsh || n.op == types.Orsh {
				nerror(n, sys.sprint("operation not defined on %s", tp(t)))
				n.ty = terror
				return n.ty
			}
		case types.Tstring:
			if n.op != types.Oadd {
				nerror(n, sys.sprint("operation not defined on %s", tp(t)))
				n.ty = terror
				return n.ty
			}
		default:
			nerror(n, sys.sprint("operation not defined on %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		n.ty = t
		if n.left.op == types.Oconst && n.right.op == types.Oconst {
			if fold.confoldbin(n) == 0 {
				nerror(n, "division by zero in constant expression")
			}
		}
		return n.ty
	case types.Ocons:
		et := echk(n.left)
		tr := echk(n.right)
		if et == terror || tr == terror {
			n.ty = terror
			return n.ty
		}
		if tr == tany {
			if et.kind == types.Tref && et.tof != nil && et.tof.kind == types.Tadtpick && et.tof.tof != nil {
				et = types.mktype(n.line, n.pos, types.Tref, et.tof.tof, nil)
				types.sizetype(et)
			} else if et.kind == types.Tadtpick && et.tof != nil {
				et = et.tof
			}
			n.ty = types.mktype(n.line, n.pos, types.Tlist, et, nil)
			types.sizetype(n.ty)
			return n.ty
		}
		if tr.kind != types.Tlist {
			nerror(n, sys.sprint("cannot :: to %s", tp(tr)))
			n.ty = terror
			return n.ty
		}
		if assignable(tr.tof, et, n.left) == 0 {
			nerror(n, sys.sprint("type mismatch in %s :: %s", tp(et), tp(tr)))
			n.ty = terror
			return n.ty
		}
		n.ty = tr
		return n.ty
	case types.Oeq, types.Oneq, types.Olt, types.Ogt, types.Oleq, types.Ogeq:
		t := echk(n.left)
		tr := echk(n.right)
		if t != terror && tr != terror && assignable(t, tr, n.right) == 0 && assignable(tr, t, n.left) == 0 {
			nerror(n, sys.sprint("type mismatch: %s %s %s", tp(t), types.opname(n.op), tp(tr)))
		} else if t != terror && (t.kind == types.Tadt || t.kind == types.Ttuple || t.kind == types.Tadtpick) {
			nerror(n, sys.sprint("cannot compare %s values: compare the fields, or compare refs", tp(t)))
		} else if t != terror && isnum(t) == 0 && t.kind != types.Tstring && n.op != types.Oeq && n.op != types.Oneq {
			nerror(n, sys.sprint("ordering is not defined on %s", tp(t)))
		}
		n.ty = tint
		return n.ty
	case types.Oandand, types.Ooror:
		echk(n.left)
		echk(n.right)
		n.ty = tint
		return n.ty
	case types.Onot:
		echk(n.left)
		n.ty = tint
		return n.ty
	case types.Oneg:
		t := echk(n.left)
		if isnum(t) == 0 {
			nerror(n, sys.sprint("cannot negate %s", tp(t)))
			t = terror
		}
		if n.left.op == types.Oconst && (n.left.flags & types.NSTR) == 0 {
			p := n.left
			n.op = types.Oconst
			n.flags = p.flags
			if (p.flags & types.NREAL) != 0 {
				n.rval = -p.rval
			} else {
				n.val = -p.val
			}
			n.left = nil
		}
		n.ty = t
		return n.ty
	case types.Oinv:
		t := echk(n.left)
		if t.kind != types.Tint && t.kind != types.Tbig && t.kind != types.Tbyte {
			nerror(n, sys.sprint("cannot complement %s", tp(t)))
			t = terror
		}
		if n.left.op == types.Oconst && (n.left.flags & (types.NSTR | types.NREAL)) == 0 {
			p := n.left
			n.op = types.Oconst
			n.val = ~p.val
			n.left = nil
		}
		n.ty = t
		return n.ty
	case types.Oindex:
		t := echk(n.left)
		echk(n.right)
		if t.kind == types.Tarray {
			n.op = types.Oindx
			n.ty = t.tof
			return n.ty
		}
		if t.kind == types.Tstring {
			n.op = types.Oinds
			n.ty = tint
			return n.ty
		}
		nerror(n, sys.sprint("cannot index %s", tp(t)))
		n.ty = terror
		return n.ty
	case types.Oslice:
		t := echk(n.left)
		if n.right != nil {
			if n.right.left != nil {
				echk(n.right.left)
			}
			if n.right.right != nil {
				echk(n.right.right)
			}
		}
		if t.kind != types.Tarray && t.kind != types.Tstring {
			nerror(n, sys.sprint("cannot slice %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		n.ty = t
		return n.ty
	case types.Ochk:
		rt := echk(n.left)
		subj := rt
		if subj != nil && subj.kind == types.Tref {
			subj = subj.tof
		}
		if subj == nil || subj.kind != types.Tadt || subj.tags == nil || rt.kind != types.Tref {
			nerror(n, sys.sprint("? requires a ref to a pick adt (e.g. ref Result), not %s", tp(rt)))
			n.ty = terror
			return n.ty
		}
		if assignable(curret, rt, n.left) == 0 {
			nerror(n, sys.sprint("? used in a function returning %s, not %s", tp(curret), tp(rt)))
			n.ty = terror
			return n.ty
		}
		tag := subj.tags
		nfields := 0
		for fd := tag.ty.ids; fd != nil; fd = fd.next {
			nfields++
		}
		if nfields > 1 {
			nerror(n, sys.sprint("? requires %s's success tag %s to have zero or one field, not %d", tp(subj), tag.sym, nfields))
			n.ty = terror
			return n.ty
		}
		fd := tag.ty.ids
		n.decl = fd
		if fd == nil {
			n.ty = tnone
		} else {
			n.ty = fd.ty
		}
		return n.ty
	case types.Oref:
		var t ref types.Type
		if n.left.op == types.Ocomposite {
			t = compositefields(n.left)
		} else {
			t = echk(n.left)
		}
		if t.kind != types.Tadt && t.kind != types.Tadtpick {
			nerror(n, sys.sprint("ref of non-adt %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		n.ty = types.mktype(n.line, n.pos, types.Tref, t, nil)
		types.sizetype(n.ty)
		return n.ty
	case types.Ochan:
		if n.left != nil {
			t := echk(n.left)
			if t != tint && t != terror {
				nerror(n, sys.sprint("channel size must be int, not %s", tp(t)))
			}
		}
		t := types.mktype(n.line, n.pos, types.Tchan, stype(n.right), nil)
		types.sizetype(t)
		n.right = nil
		n.ty = t
		return n.ty
	case types.Oarray:
		t := echk(n.left)
		if t != tint && t != terror {
			nerror(n, sys.sprint("array size must be int, not %s", tp(t)))
		}
		t = types.mktype(n.line, n.pos, types.Tarray, stype(n.right), nil)
		types.sizetype(t)
		n.right = nil
		if n.aux != nil {
			nelem := 0
			for p := n.aux; p != nil; p = p.right {
				e := seqitem(p)
				ety := echk(e.right)
				if assignable(t.tof, ety, e.right) == 0 {
					nerror(e, sys.sprint("cannot use %s as %s in array composite literal", tp(ety), tp(t.tof)))
				}
				nelem++
				if p.op != types.Oseq {
					break
				}
			}
			if n.left.op != types.Oconst || n.left.ty != tint {
				nerror(n, "array composite literal size must be a constant")
			} else if n.left.val != big(nelem) {
				nerror(n, sys.sprint("array size %bd does not match %d elements in composite literal", n.left.val, nelem))
			}
		}
		n.ty = t
		return n.ty
	case types.Orcv:
		t := echk(n.left)
		if t.kind != types.Tchan {
			nerror(n, sys.sprint("receive from non-channel %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		n.ty = t.tof
		return n.ty
	case types.Osnd:
		t := echk(n.left)
		tr := echk(n.right)
		if t.kind != types.Tchan {
			nerror(n, sys.sprint("send to non-channel %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		retypetuple(n.right, t.tof)
		if assignable(t.tof, tr, n.right) == 0 {
			nerror(n, sys.sprint("cannot send %s on %s", tp(tr), tp(t)))
		}
		n.ty = tnone
		return n.ty
	case types.Ocomposite:
		n.ty = compositefields(n)
		return n.ty
	case types.Otuple:
		var ids ref types.Decl
		var last ref types.Decl
		i := 0
		for p := n.left; p != nil; p = p.right {
			e := seqitem(p)
			t := echk(e)
			d := types.mkdecl(e.line, e.pos, types.Dfield, t)
			d.sym = sys.sprint("t%d", i)
			i++
			if ids == nil {
				ids = d
			} else {
				last.next = d
			}
			last = d
			if p.op != types.Oseq {
				break
			}
		}
		n.ty = types.mktype(n.line, n.pos, types.Ttuple, nil, ids)
		types.sizetype(n.ty)
		return n.ty
	case types.Ofunclit:
		ld := synthfunclit(n)
		if ld == nil {
			n.ty = terror
			return n.ty
		}
		n.op = types.Oname
		n.decl = ld
		n.sym = ld.sym
		n.right = nil
		n.aux = nil
		n.ty = types.mktype(n.line, n.pos, types.Tref, ld.ty, nil)
		types.sizetype(n.ty)
		return n.ty
	case types.Ocast:
		t := stype(n.right)
		n.right = nil
		tt := echk(n.left)
		if t == terror || tt == terror {
			n.ty = terror
			return n.ty
		}
		types.sizetype(t)
		if types.castable(tt, t) == 0 {
			nerror(n, sys.sprint("cannot convert %s to %s", tp(tt), tp(t)))
			n.ty = terror
			return n.ty
		}
		n.ty = t
		if n.left.op == types.Oconst {
			fold.confoldcast(n)
		}
		return n.ty
	case types.Oload:
		if n.left.op != types.Oname {
			nerror(n, "load needs a module name")
			n.ty = terror
			return n.ty
		}
		v := lookup(n.left.sym)
		if v == nil || v.ty == nil || v.ty.kind != types.Tmodule || (v.store != types.Dtype && v.importid == nil) {
			nerror(n, sys.sprint("%s is not an imported module", n.left.sym))
			n.ty = terror
			return n.ty
		}
		if v.store == types.Dtype {
			var found ref types.Decl
			for l := imports; l != nil; l = tl(l) {
				if hd(l).importid == v {
					found = hd(l)
					break
				}
			}
			if found == nil {
				nerror(n, sys.sprint("%s is not an imported module", n.left.sym))
				n.ty = terror
				return n.ty
			}
			v = found
		}
		t := echk(n.right)
		if t != terror && t != tstring {
			nerror(n, sys.sprint("load path must be a string, not %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		n.decl = v
		n.left = nil
		n.ty = v.ty
		return n.ty
	}
	nerror(n, sys.sprint("unsupported expression %s", types.opname(n.op)))
	n.ty = terror
	return n.ty
}

func chkdot(n ref types.Node) ref types.Type {
	if n.left.op == types.Oname {
		d := lookup(n.left.sym)
		if d != nil && d.ty != nil && d.ty.kind == types.Tmodule && ismodvar(d) != 0 {
			id := modmember(d.ty, n.sym)
			if id == nil {
				nerror(n, sys.sprint("%s has no member %s", n.left.sym, n.sym))
				n.ty = terror
				return n.ty
			}
			match id.store {
			case types.Dconst:
				if confold(n, id) != 0 {
					return n.ty
				}
				nerror(n, sys.sprint("constant %s.%s is not usable here", n.left.sym, n.sym))
				n.ty = terror
				return n.ty
			case types.Dfn:
				wd := synthimportwrap(n.line, n.pos, d, id)
				if wd == nil {
					n.ty = terror
					return n.ty
				}
				n.op = types.Oname
				n.left = nil
				n.right = nil
				n.decl = wd
				n.sym = wd.sym
				n.ty = wd.valty
				return n.ty
			case types.Dglobal:
				// alias.var -> Oind(Oadd(Oind(alias), $off)): the
				// module link's first word is the data pointer and
				// the variable sits at its .mp record offset
				d.refs++
				id.refs++
				if d.ty.tof == nil {
					types.sizetype(d.ty)
				}
				mp := id.iface
				if mp == nil || mp.ty == nil {
					nerror(n, sys.sprint("%s.%s: the interface exports no module data", n.left.sym, n.sym))
					n.ty = terror
					return n.ty
				}
				types.sizetype(mp.ty)
				c := mp.ty.ids
				for c != nil && c.iface != id {
					c = c.next
				}
				if c == nil {
					fatal(sys.sprint("%s.%s missing from the .mp record", n.left.sym, n.sym))
				}
				n.left.decl = d
				n.left.ty = d.ty
				inner := types.mkunary(types.Oind, n.left)
				inner.line = n.line
				inner.pos = n.pos
				inner.ty = tint
				off := mkconst(n.line, n.pos, big(c.offset))
				off.ty = tint
				addr := types.mkn(types.Oadd, inner, off)
				addr.line = n.line
				addr.pos = n.pos
				addr.ty = tint
				n.op = types.Oind
				n.left = addr
				n.right = nil
				n.decl = nil
				n.ty = id.ty
				return n.ty
			case types.Dtype:
				d.refs++
				id.refs++
				n.op = types.Omdot
				n.left.decl = d
				n.left.ty = d.ty
				n.right = types.mkn(types.Oname, nil, nil)
				n.right.line = n.line
				n.right.pos = n.pos
				n.right.sym = n.sym
				n.right.decl = id
				n.right.ty = id.ty
				n.ty = id.ty
				return n.ty
			}
			nerror(n, sys.sprint("cannot use %s.%s here", n.left.sym, n.sym))
			n.ty = terror
			return n.ty
		}
	}
	bt := echk(n.left)
	t := bt
	isref := 0
	if bt != nil && bt.kind == types.Tref {
		isref = 1
		t = bt.tof
	}
	if t != nil && (t.kind == types.Tadt || t.kind == types.Tadtpick || t.kind == types.Ttuple) {
		var chain1 ref types.Decl
		if t.kind == types.Tadtpick {
			chain1 = t.tof.ids
		}
		for ci := 0; ci < 2; ci++ {
			ids := t.ids
			if ci == 1 {
				ids = chain1
			}
			for id := ids; id != nil; id = id.next {
				if id.sym == n.sym {
					fty := id.ty
					off := mkconst(n.line, n.pos, big(id.offset))
					off.ty = tint
					var addr ref types.Node
					if isref != 0 {
						addr = types.mkn(types.Oadd, n.left, off)
					} else {
						adr := types.mkunary(types.Oadr, n.left)
						adr.line = n.line
						adr.pos = n.pos
						adr.ty = bt
						addr = types.mkn(types.Oadd, adr, off)
					}
					addr.line = n.line
					addr.pos = n.pos
					addr.ty = tint
					n.op = types.Oind
					n.left = addr
					n.right = nil
					if isref != 0 {
						n.decl = id
					} else {
						n.decl = nil
					}
					n.ty = fty
					return n.ty
				}
			}
		}
		for id := t.meths; id != nil; id = id.link {
			if id.sym == n.sym {
				n.decl = id
				n.ty = id.ty
				n.right = nil
				return n.ty
			}
		}
		if t.gtemplate != nil {
			for mtd := t.gtemplate.methtmpl; mtd != nil; mtd = mtd.link {
				if mtd.sym == n.sym {
					fnd := tinstantiatemeth(mtd, t)
					if fnd == nil {
						n.ty = terror
						return n.ty
					}
					n.decl = fnd
					n.ty = fnd.ty
					n.right = nil
					return n.ty
				}
			}
		}
		nerror(n, sys.sprint("%s has no field or method %s", tp(t), n.sym))
		n.ty = terror
		return n.ty
	}
	nerror(n, sys.sprint("field selection on %s", tp(t)))
	n.ty = terror
	return n.ty
}

func chkcall(n ref types.Node) ref types.Type {
	isvalcall := 0
	var recvdone ref types.Node
	var ft ref types.Type
	if n.left.op == types.Oname {
		td := lookup(n.left.sym)
		if td != nil && td.store == types.Dtype {
			if n.right == nil || n.right.op == types.Oseq {
				nerror(n, sys.sprint("conversion to %s needs exactly one argument", n.left.sym))
				n.ty = terror
				return n.ty
			}
			n.op = types.Ocast
			a := n.left
			n.left = n.right
			n.right = a
			return echk(n)
		}
	}
	if n.left.op == types.Oname && n.left.sym == "len" {
		a := n.right
		if a == nil {
			nerror(n, "len needs an argument")
			n.ty = terror
			return n.ty
		}
		e := seqitem(a)
		t := echk(e)
		if t.kind != types.Tarray && t.kind != types.Tstring && t.kind != types.Tlist {
			nerror(n, sys.sprint("len of %s", tp(t)))
			n.ty = terror
			return n.ty
		}
		n.op = types.Olen
		n.left = e
		n.right = nil
		n.ty = tint
		return n.ty
	}
	if n.left.op == types.Oname && (n.left.sym == "hd" || n.left.sym == "tl") {
		ishd := 0
		if n.left.sym == "hd" {
			ishd = 1
		}
		a := n.right
		if a == nil {
			if ishd != 0 {
				nerror(n, "hd needs an argument")
			} else {
				nerror(n, "tl needs an argument")
			}
			n.ty = terror
			return n.ty
		}
		e := seqitem(a)
		t := echk(e)
		if t.kind != types.Tlist || t.tof == nil {
			if ishd != 0 {
				nerror(n, sys.sprint("cannot hd %s", tp(t)))
			} else {
				nerror(n, sys.sprint("cannot tl %s", tp(t)))
			}
			n.ty = terror
			return n.ty
		}
		if ishd != 0 {
			n.op = types.Ohd
			n.ty = t.tof
		} else {
			n.op = types.Otl
			n.ty = t
		}
		n.left = e
		n.right = nil
		return n.ty
	}
	var ld ref types.Decl
	if n.left.op == types.Oname {
		ld = lookup(n.left.sym)
	}
	if n.left.op == types.Otinst || n.left.op == types.Oindex {
		fnd := tinstantiatefn(n.left)
		if fnd == nil {
			n.ty = terror
			return n.ty
		}
		n.left = mkidname(fnd.line, fnd.pos, fnd)
		ft = fnd.ty
	} else if n.left.op == types.Oname && ld != nil && ld.store == types.Dfn && ld.tparams != nil {
		fnd := inferfn(n)
		if fnd == nil {
			n.ty = terror
			return n.ty
		}
		n.left = mkidname(fnd.line, fnd.pos, fnd)
		ft = fnd.ty
	} else if n.left.op == types.Oname && ld != nil && ld.store == types.Dfn {
		ld.refs++
		n.left.decl = ld
		n.left.ty = ld.ty
		ft = ld.ty
	} else if n.left.op == types.Odot && modcallee(n.left) != nil {
		alias := lookup(n.left.left.sym)
		fnd := modmember(alias.ty, n.left.sym)
		alias.refs++
		fnd.refs++
		n.left.op = types.Omdot
		n.left.left.decl = alias
		n.left.left.ty = alias.ty
		n.left.right = types.mkn(types.Oname, nil, nil)
		n.left.right.line = n.left.line
		n.left.right.pos = n.left.pos
		n.left.right.sym = n.left.sym
		n.left.right.decl = fnd
		n.left.right.ty = fnd.ty
		n.left.ty = fnd.ty
		ft = fnd.ty
	} else {
		match n.left.op {
		case types.Oname, types.Odot, types.Omdot, types.Ocall, types.Ofunclit:
			break
		default:
			nerror(n, "cannot call this expression")
			n.ty = terror
			return n.ty
		}
		ft = echk(n.left)
		if ft != nil && ft.kind == types.Tref && ft.tof != nil && ft.tof.kind == types.Tfn {
			ind := types.mkunary(types.Oind, n.left)
			ind.line = n.left.line
			ind.pos = n.left.pos
			ind.ty = ft.tof
			n.left = ind
			ft = ft.tof
			isvalcall = 1
		}
	}
	if ft.kind != types.Tfn {
		if ft != terror {
			nerror(n, "call of a non-function")
		}
		n.ty = terror
		return n.ty
	}
	if n.left.op == types.Odot && n.left.decl != nil && n.left.decl.store == types.Dfn {
		meth := n.left.decl
		recvexpr := n.left.left
		recvdone = recvexpr
		n.right = types.mkseq(recvexpr, n.right)
		callee := types.mkn(types.Oname, nil, nil)
		callee.line = n.left.line
		callee.pos = n.left.pos
		callee.sym = meth.sym
		callee.decl = meth
		callee.ty = meth.ty
		alias := methodmodule(meth)
		if alias != nil {
			alias.refs++
			meth.refs++
			modn := types.mkn(types.Oname, nil, nil)
			modn.line = n.left.line
			modn.pos = n.left.pos
			modn.sym = alias.sym
			modn.decl = alias
			modn.ty = alias.ty
			callee = types.mkbin(types.Omdot, modn, callee)
			callee.line = n.left.line
			callee.pos = n.left.pos
			callee.ty = meth.ty
		}
		n.left = callee
	}
	arg := ft.ids
	if isvalcall != 0 && arg != nil {
		arg = arg.next
	}
	i := 0
	for a := n.right; a != nil; a = a.right {
		e := seqitem(a)
		var t ref types.Type
		if e == recvdone {
			t = e.ty
		} else {
			t = echk(e)
		}
		i++
		if arg != nil {
			retypetuple(e, arg.ty)
			if assignable(arg.ty, t, e) == 0 {
				if t.kind == types.Ttuple && e.op == types.Ocall && a.op != types.Oseq && ft.varargs == 0 {
					// f(g()) with g multi-valued: its results are the
					// arguments, one per parameter (check.c)
					for fd := t.ids; fd != nil; fd = fd.next {
						if arg == nil {
							nerror(e, "too many arguments")
							break
						}
						if assignable(arg.ty, fd.ty, nil) == 0 {
							nerror(e, sys.sprint("argument %d: cannot use %s as %s", i, tp(fd.ty), tp(arg.ty)))
						}
						i++
						arg = arg.next
					}
					e.flags |= types.NSPREAD
					break
				}
				nerror(e, sys.sprint("argument %d: cannot use %s as %s", i, tp(t), tp(arg.ty)))
			}
			arg = arg.next
		} else if ft.varargs == 0 {
			nerror(e, "too many arguments")
		}
		if a.op != types.Oseq {
			break
		}
	}
	if arg != nil {
		nerror(n, "not enough arguments")
	}
	if ft.varargs != 0 {
		nft := types.mktype(n.line, n.pos, types.Tfn, ft.tof, nil)
		nft.varargs = 1
		var nids ref types.Decl
		var nlast ref types.Decl
		j := 0
		for arg = ft.ids; arg != nil; arg = arg.next {
			na := types.dupdecl(arg)
			if nids == nil {
				nids = na
			} else {
				nlast.next = na
			}
			nlast = na
			j++
		}
		if isvalcall != 0 {
			j--
		}
		i = 0
		for a := n.right; a != nil; a = a.right {
			e := seqitem(a)
			if i >= j {
				na := types.mkdecl(e.line, e.pos, types.Darg, e.ty)
				na.sym = sys.sprint(".a%d", i)
				if nids == nil {
					nids = na
				} else {
					nlast.next = na
				}
				nlast = na
			}
			i++
			if a.op != types.Oseq {
				break
			}
		}
		nft.ids = nids
		nft.ok |= types.OKverify
		types.sizetype(nft)
		types.sizeids(nft.ids, types.MaxTemp)
		n.left.ty = nft
	}
	n.ty = ft.tof
	return n.ty
}

// ---- statements

func addlocal(d ref types.Decl) {
	d.link = nil
	if curfn.locals == nil {
		curfn.locals = d
		return
	}
	e := curfn.locals
	for e.link != nil {
		e = e.link
	}
	e.link = d
}

func declocal(id ref types.Node, t ref types.Type) ref types.Decl {
	types.sizetype(t)
	d := types.mkdecl(id.line, id.pos, types.Dlocal, t)
	d.sym = id.sym
	install(d)
	id.decl = d
	id.ty = t
	addlocal(d)
	return d
}

func daschk(n ref types.Node) {
	lhs := n.left
	if lhs.op == types.Oseq {
		if n.right.op == types.Oseq {
			n.right = types.mkn(types.Otuple, n.right, nil)
		}
		t := echk(n.right)
		if t.kind != types.Ttuple {
			nerror(n, sys.sprint("multiple assignment needs a multi-valued call or an expression list on the right, not %s", tp(t)))
			return
		}
		nlhs := seqcount(lhs)
		nrhs := 0
		for fd := t.ids; fd != nil; fd = fd.next {
			nrhs++
		}
		if nlhs != nrhs {
			nerror(n, sys.sprint("assignment count mismatch: %d = %d", nlhs, nrhs))
			return
		}
		fd := t.ids
		for p := lhs; p != nil; p = p.right {
			id := seqitem(p)
			if id.op != types.Oname {
				nerror(n, "unsupported := form")
				return
			}
			declocal(id, fd.ty)
			fd = fd.next
			if p.op != types.Oseq {
				break
			}
		}
		n.ty = t
		return
	}
	if lhs.op != types.Oname {
		nerror(n, "unsupported := form")
		return
	}
	var t ref types.Type
	if n.right.op == types.Ocomposite {
		t = compositefields(n.right)
	} else {
		t = echk(n.right)
	}
	if t == tnone {
		nerror(n, ":= of a void expression")
		t = terror
	}
	if t == tany {
		nerror(n, ":= of nil needs a type")
		t = terror
	}
	if t.kind == types.Tfn {
		nerror(n, "a method is not a value: call it, or wrap it in a closure")
		t = terror
	}
	declocal(lhs, t)
	n.ty = t
}

func casecmp(ty ref types.Type, a ref types.Node, b ref types.Node) int {
	if ty == tstring {
		if a.sym < b.sym {
			return -1
		}
		if a.sym > b.sym {
			return 1
		}
		return 0
	}
	if a.val < b.val {
		return -1
	}
	if a.val > b.val {
		return 1
	}
	return 0
}

func casesort(t ref types.Type, aux []ref types.Label, labs []ref types.Label, start int, stop int) {
	n := stop - start
	if n <= 1 {
		return
	}
	top := start + n / 2
	mid := top
	casesort(t, aux, labs, start, top)
	casesort(t, aux, labs, mid, stop)
	n = 0
	base := start
	for base < top && mid < stop {
		if casecmp(t, labs[base].start, labs[mid].start) <= 0 {
			aux[n] = labs[base]
			base++
		} else {
			aux[n] = labs[mid]
			mid++
		}
		n++
	}
	for base < top {
		aux[n] = labs[base]
		base++
		n++
	}
	for mid < stop {
		aux[n] = labs[mid]
		mid++
		n++
	}
	for i := 0; i < stop - start; i++ {
		labs[start + i] = aux[i]
	}
}

func matchlabels(arms ref types.Node, ctype ref types.Type, nlab int) ref types.Case {
	labs := [nlab + 1]ref types.Label
	i := 0
	var wild ref types.Node
	for p := arms; p != nil; {
		arm := p
		if p.op == types.Oseq {
			arm = p.left
			p = p.right
		} else {
			p = nil
		}
		if arm.left == nil {
			wild = arm
			continue
		}
		for pat := arm.left; pat != nil; {
			q := seqitem(pat)
			labs[i] = ref types.Label{node: arm, isptr: 0, start: q, stop: q, inst: nil}
			i++
			if pat.op != types.Oseq {
				break
			}
			pat = pat.right
		}
	}
	if i != nlab {
		error(0, sys.sprint("fatal: matchlabels: bad label count %d vs %d", nlab, i))
	}
	aux := [nlab + 1]ref types.Label
	casesort(ctype, aux, labs, 0, nlab)
	for i = 0; i < nlab; i++ {
		stop := labs[i].stop
		if casecmp(ctype, labs[i].start, stop) > 0 {
			nerror(labs[i].start, "unmatchable case label")
		}
		e := i + 1
		for ; e < nlab; e++ {
			if casecmp(ctype, labs[e].start, stop) <= 0 {
				if ctype == tstring {
					nerror(labs[e].start, sys.sprint("duplicate case label \"%s\"", labs[e].start.sym))
				} else {
					nerror(labs[e].start, sys.sprint("case label %bd overlaps %bd", labs[e].start.val, stop.val))
				}
			}
			if ctype != tint || labs[e].start.val != stop.val + big(1) || labs[e].node != labs[i].node {
				break
			}
			stop = labs[e].stop
		}
		if e != i + 1 {
			labs[i].stop = stop
			k := i + 1
			for m := e; m < nlab; m++ {
				labs[k] = labs[m]
				k++
			}
			nlab -= e - (i + 1)
		}
	}
	return ref types.Case{nlab: nlab, nsnd: 0, offset: 0, labs: labs, wild: wild, iwild: nil, tagof: nil}
}

func altcheck(n ref types.Node) {
	ok := 1
	nsnd := 0
	nrcv := 0
	var wild ref types.Node
	for p := n.right; p != nil; {
		arm := p
		if p.op == types.Oseq {
			arm = p.left
			p = p.right
		} else {
			p = nil
		}
		g := arm.left
		arm.aux = nil
		if g == nil {
			if wild != nil {
				nerror(arm, "alt has more than one default")
			}
			wild = arm
			pushscope()
			stchk(arm.right)
			popscope()
			continue
		}
		pushscope()
		var comm ref types.Node
		bad := 0
		match g.op {
		case types.Osnd:
			echk(g)
			if g.ty != terror {
				comm = g
				nsnd++
			} else {
				ok = 0
			}
		case types.Oexpr:
			if g.left.op != types.Orcv {
				bad = 1
			} else {
				echk(g.left)
				if g.left.ty != terror {
					comm = g.left
					nrcv++
				} else {
					ok = 0
				}
			}
		case types.Odas:
			if g.left.op != types.Oname || g.right.op != types.Orcv {
				bad = 1
			} else {
				daschk(g)
				if g.ty != terror && g.right.ty != terror && g.left.decl != nil {
					comm = g.right
					nrcv++
				} else {
					ok = 0
				}
			}
		case types.Oas:
			if g.left.op == types.Oseq || g.right.op != types.Orcv {
				bad = 1
			} else {
				stchk(g)
				if g.left.ty != terror && g.right.ty != terror {
					comm = g.right
					nrcv++
				} else {
					ok = 0
				}
			}
		default:
			bad = 1
		}
		if bad != 0 {
			nerror(g, "alt case must be a send, a receive, or a receive into a variable")
			ok = 0
		}
		arm.aux = comm
		stchk(arm.right)
		popscope()
	}
	if ok == 0 {
		return
	}
	c := ref types.Case{nlab: nsnd + nrcv, nsnd: nsnd, offset: 0, labs: nil, wild: wild, iwild: nil, tagof: nil}
	c.labs = [c.nlab + 1]ref types.Label
	for i := 0; i <= c.nlab; i++ {
		c.labs[i] = ref types.Label{}
	}
	n.ty = types.mktalt(c)
}

func istagname(n ref types.Node) int {
	if n == nil {
		return 0
	}
	if n.op == types.Oname {
		d := lookup(n.sym)
		return d != nil && d.store == types.Dtype
	}
	if n.op == types.Odot {
		if n.left.op == types.Odot {
			return 1
		}
		if n.left.op != types.Oname {
			return 0
		}
		d := lookup(n.left.sym)
		return d != nil && d.store == types.Dtype
	}
	return 0
}

func matchcheck(n ref types.Node) {
	t := echk(n.left)
	ok := 1
	subj := t
	if t != nil && t.kind == types.Tref {
		subj = t.tof
	}
	if subj != nil && subj.kind == types.Tadtpick {
		subj = subj.tof
	}
	if subj == nil || subj.kind != types.Tadt || subj.tags == nil {
		subj = nil
	}
	if subj == nil && t != tint && t != tstring && t != terror {
		nerror(n, sys.sprint("match subject must be int, string or a tagged adt, not %s", tp(t)))
		ok = 0
	}
	labty := tint
	if t == tstring {
		labty = tstring
	}
	var wild ref types.Node
	nlab := 0
	for p := n.right; p != nil; {
		arm := p
		if p.op == types.Oseq {
			arm = p.left
			p = p.right
		} else {
			p = nil
		}
		if arm.left == nil {
			if wild != nil {
				nerror(arm, "match has more than one default")
			}
			wild = arm
		} else {
			npat := 0
			for pat := arm.left; pat != nil; npat++ {
				q := seqitem(pat)
				if pat.op == types.Oseq {
					pat = pat.right
				} else {
					pat = nil
				}
				if q.op == types.Opat && q.right == nil && istagname(q.left) == 0 {
					echk(q.left)
					if q.left.op == types.Oconst {
						lab := q.left
						q.op = types.Oconst
						q.flags = lab.flags
						q.val = lab.val
						q.rval = lab.rval
						q.sym = lab.sym
						q.ty = lab.ty
						q.left = nil
						q.right = nil
						q.decl = nil
					} else {
						nerror(q, "case label is not a constant or a tag")
						ok = 0
						continue
					}
				}
				if q.op == types.Opat {
					if subj == nil {
						nerror(q, "tag pattern needs a tagged-adt match subject")
						ok = 0
						continue
					}
					if npat != 0 || pat != nil {
						nerror(q, "a tag pattern must be the only pattern in its case")
						ok = 0
						continue
					}
					tagty := stype(q.left)
					if tagty.kind != types.Tadtpick || tagty.tof != subj {
						nerror(q, sys.sprint("%s is not a tag of the match subject's type %s", tp(tagty), tp(subj)))
						ok = 0
						continue
					}
					q.left.ty = tagty
					q.val = big(tagty.decl.tag)
					nlab++
					pushscope()
					fd := tagty.ids
					var bp ref types.Decl
					for bn := q.right; bn != nil && fd != nil; bn = bn.right {
						id := seqitem(bn)
						if id.op != types.Oname {
							nerror(id, "bad pattern binder")
							ok = 0
							break
						}
						types.sizetype(fd.ty)
						d := types.mkdecl(id.line, id.pos, types.Dlocal, fd.ty)
						d.sym = id.sym
						install(d)
						id.decl = d
						id.ty = fd.ty
						d.link = nil
						if bp == nil {
							addlocal(d)
						} else {
							bp.link = d
						}
						bp = d
						fd = fd.next
						if bn.op != types.Oseq {
							break
						}
					}
					stchk(arm.right)
					popscope()
					continue
				}
				pt := echk(q)
				if pt != terror && pt != labty {
					if t == tstring {
						nerror(q, sys.sprint("case label must be string, not %s", tp(pt)))
					} else {
						nerror(q, sys.sprint("case label must be int, not %s", tp(pt)))
					}
					ok = 0
				} else if q.op != types.Oconst {
					nerror(q, "case label is not constant")
					ok = 0
				} else {
					nlab++
				}
			}
		}
		if arm.left == nil || arm.left.op != types.Opat {
			pushscope()
			stchk(arm.right)
			popscope()
		}
	}
	if ok == 0 || (subj == nil && t != tint && t != tstring) {
		return
	}
	c := matchlabels(n.right, labty, nlab)
	c.tagof = subj
	kind := types.Tcase
	if t == tstring {
		kind = types.Tcasec
	}
	ct := types.mktype(n.line, n.pos, kind, nil, nil)
	ct.cse = c
	types.sizetype(ct)
	n.ty = ct
}

func lvaldesc(n ref types.Node) string {
	match n.op {
	case types.Oname:
		d := n.decl
		if d == nil {
			return nil
		}
		if d == nildecl {
			return "nil"
		}
		match d.store {
		case types.Dfn:
			return "a function"
		case types.Dtype:
			return "a type"
		case types.Dtag:
			return "a pick tag"
		}
		return nil
	case types.Omdot:
		if n.right.decl != nil && n.right.decl.store == types.Dtype {
			return "a type"
		}
		return nil
	case types.Oconst:
		return "a constant"
	case types.Onil:
		return "nil"
	case types.Ocall:
		return "a function call"
	case types.Oslice:
		return "a slice"
	case types.Otuple:
		return "a tuple"
	case types.Ocomposite, types.Oref:
		return "a composite literal"
	case types.Olen, types.Ohd, types.Otl, types.Ocons, types.Ocast, types.Oneg, types.Onot, types.Oinv, types.Oadd, types.Osub, types.Omul, types.Odiv, types.Omod, types.Oand, types.Oor, types.Oxor, types.Olsh, types.Orsh, types.Oandand, types.Ooror, types.Oeq, types.Oneq, types.Olt, types.Ogt, types.Oleq, types.Ogeq, types.Orcv, types.Ochk:
		return "an expression"
	}
	return nil
}

func islvalue(n ref types.Node) int {
	match n.op {
	case types.Oname:
		d := n.decl
		if d == nil || d == nildecl {
			return 0
		}
		return d.store == types.Dlocal || d.store == types.Darg || d.store == types.Dglobal
	case types.Omdot:
		return n.right.decl != nil && n.right.decl.store == types.Dglobal
	case types.Oindx:
		return 1
	case types.Oinds:
		return islvalue(n.left)
	case types.Oind:
		b := n.left
		for b.op == types.Oadd {
			b = b.left
		}
		if b.op == types.Oadr {
			return islvalue(b.left)
		}
		return 1
	}
	return 0
}

func chklval(n ref types.Node, what string) int {
	if n.ty == terror {
		return 0
	}
	if islvalue(n) != 0 {
		return 1
	}
	desc := lvaldesc(n)
	if desc == nil && n.op == types.Oind {
		b := n.left
		for b.op == types.Oadd {
			b = b.left
		}
		if b.op == types.Oadr {
			desc = lvaldesc(b.left)
		}
		if desc != nil {
			nerror(n, sys.sprint("cannot %s a field of %s", what, desc))
			return 0
		}
	}
	if desc == nil && n.op == types.Oinds {
		desc = lvaldesc(n.left)
		if desc != nil {
			nerror(n, sys.sprint("cannot %s an element of %s", what, desc))
			return 0
		}
	}
	if desc == nil {
		desc = "this expression"
	}
	nerror(n, sys.sprint("cannot %s %s", what, desc))
	return 0
}

func stchk(n ref types.Node) {
	for ; n != nil; n = n.right {
		match n.op {
		case types.Oseq:
			stchk(n.left)
			continue
		case types.Oscope:
			pushscope()
			stchk(n.left)
			popscope()
			return
		case types.Oif:
			echk(n.left)
			pushscope()
			stchk(n.right)
			popscope()
			if n.aux != nil {
				pushscope()
				stchk(n.aux)
				popscope()
			}
			return
		case types.Omatch:
			matchcheck(n)
			return
		case types.Oalt:
			altcheck(n)
			return
		case types.Ofor:
			pushscope()
			if n.aux != nil {
				stchk(n.aux.left)
			}
			if n.left != nil {
				echk(n.left)
			}
			pushscope()
			stchk(n.right)
			popscope()
			if n.aux != nil {
				stchk(n.aux.right)
			}
			popscope()
			return
		case types.Obreak, types.Ocont:
			return
		case types.Olabel:
			stchk(n.right)
			return
		case types.Ovardecl:
			var vt ref types.Type
			if n.right != nil {
				vt = stype(n.right)
			}
			if n.aux != nil {
				var it ref types.Type
				if n.aux.op == types.Ocomposite {
					it = compositefields(n.aux)
				} else {
					it = echk(n.aux)
				}
				if vt == nil {
					vt = it
				} else if assignable(vt, it, n.aux) == 0 {
					nerror(n, sys.sprint("cannot initialize %s from %s", tp(vt), tp(it)))
				}
			}
			if vt == nil {
				nerror(n, "variable needs a type")
				vt = terror
			}
			types.sizetype(vt)
			for names := n.left; names != nil; names = names.right {
				id := seqitem(names)
				d := types.mkdecl(id.line, id.pos, types.Dlocal, vt)
				d.sym = id.sym
				d.init = n.aux
				install(d)
				id.decl = d
				id.ty = vt
				addlocal(d)
				if names.op != types.Oseq {
					break
				}
			}
			return
		case types.Oret:
			if n.left == nil {
				if curret != tnone {
					nerror(n, "missing return value")
				}
				return
			}
			if n.left.op == types.Oseq && curret.kind == types.Ttuple {
				n.left = types.mkn(types.Otuple, n.left, nil)
			}
			var t ref types.Type
			if n.left.op == types.Ocomposite {
				t = compositefields(n.left)
			} else {
				t = echk(n.left)
			}
			retypetuple(n.left, curret)
			if t.kind == types.Ttuple {
				types.sizetype(t)
			}
			if curret == tnone {
				nerror(n, "function returns no value")
			} else if assignable(curret, t, n.left) == 0 {
				nerror(n, sys.sprint("cannot return %s as %s", tp(t), tp(curret)))
			}
			return
		case types.Odas:
			daschk(n)
			return
		case types.Oas:
			aschk(n)
			return
		case types.Oaddas, types.Osubas, types.Omulas, types.Odivas, types.Omodas, types.Oandas, types.Ooras, types.Oxoras, types.Olshas, types.Orshas:
			echk(n.left)
			echk(n.right)
			if chklval(n.left, "assign to") != 0 && n.right.ty != terror && types.tequal(n.left.ty, n.right.ty) == 0 {
				shiftok := 0
				if (n.op == types.Olshas || n.op == types.Orshas) && n.right.ty == tint && (n.left.ty.kind == types.Tbig || n.left.ty.kind == types.Tbyte) {
					shiftok = 1
				}
				if shiftok == 0 {
					nerror(n, sys.sprint("type mismatch in %s", types.opname(n.op)))
				}
			}
			return
		case types.Oinc, types.Odec:
			echk(n.left)
			if n.op == types.Oinc {
				chklval(n.left, "increment")
			} else {
				chklval(n.left, "decrement")
			}
			return
		case types.Oexpr:
			echk(n.left)
			return
		case types.Ospawn:
			echk(n.left)
			if n.left.op == types.Ocall && n.left.ty != tnone && n.left.ty != terror {
				nerror(n, "spawned function must not return a value")
			}
			return
		case types.Oraise:
			echk(n.left)
			if n.left.ty != tstring && n.left.ty != terror {
				nerror(n, "raise requires a string, not " + tp(n.left.ty))
			}
			return
		case types.Osnd:
			echk(n)
			return
		case types.Onothing:
			return
		}
		nerror(n, sys.sprint("unsupported statement %s", types.opname(n.op)))
		return
	}
}

func aschk(n ref types.Node) {
	if n.left.op == types.Oseq {
		if n.right.op == types.Oseq {
			n.right = types.mkn(types.Otuple, n.right, nil)
		}
		rt := echk(n.right)
		if rt.kind != types.Ttuple {
			nerror(n, sys.sprint("multiple assignment needs a multi-valued call or an expression list on the right, not %s", tp(rt)))
			return
		}
		nlhs := seqcount(n.left)
		nrhs := 0
		for fd := rt.ids; fd != nil; fd = fd.next {
			nrhs++
		}
		if nlhs != nrhs {
			nerror(n, sys.sprint("assignment count mismatch: %d = %d", nlhs, nrhs))
			return
		}
		fd := rt.ids
		for p := n.left; p != nil; p = p.right {
			id := seqitem(p)
			lt := echk(id)
			if chklval(id, "assign to") != 0 && assignable(lt, fd.ty, nil) == 0 {
				nerror(n, sys.sprint("cannot assign %s to %s", tp(fd.ty), tp(lt)))
			}
			fd = fd.next
			if p.op != types.Oseq {
				break
			}
		}
		n.ty = rt
		return
	}
	if n.left.op == types.Oname && n.right.op == types.Ocomposite {
		t := compositefields(n.right)
		echk(n.left)
		if chklval(n.left, "assign to") != 0 && t != terror && assignable(n.left.ty, t, n.right) == 0 {
			nerror(n, sys.sprint("cannot assign %s to %s", tp(t), tp(n.left.ty)))
		}
		return
	}
	t := echk(n.right)
	echk(n.left)
	if n.left.ty != nil {
		retypetuple(n.right, n.left.ty)
	}
	if chklval(n.left, "assign to") != 0 && assignable(n.left.ty, t, n.right) == 0 {
		nerror(n, sys.sprint("cannot assign %s to %s", tp(t), tp(n.left.ty)))
	}
}

// ---- declarations

func fnchk(d ref types.Decl) {
	curfn = d
	curret = d.ty.tof
	body := d.init.aux
	pushscope()
	for arg := d.ty.ids; arg != nil; arg = arg.next {
		if arg.sym != nil {
			arg.scope = scope
			arg.old = lookup(arg.sym)
			setbind(arg.sym, arg)
		}
	}
	stchk(body)
	for arg := d.ty.ids; arg != nil; arg = arg.next {
		if arg.sym != nil && lookup(arg.sym) == arg {
			setbind(arg.sym, arg.old)
			arg.old = nil
		}
	}
	popscope()
	curfn = nil
}

func typedec(n ref types.Node) {
	d := n.decl
	var ph ref types.Type
	if d != nil {
		ph = d.ty
	} else {
		d = types.mkdecl(n.line, n.pos, types.Dtype, nil)
		d.sym = n.left.sym
		d.dot = impdecl
		install(d)
	}
	if n.aux != nil {
		if n.right.op != types.Otstruct {
			nerror(n, sys.sprint("generic type %s: only struct bodies are supported (not tagged/pick types)", d.sym))
			d.ty = terror
			return
		}
		t := types.mktype(n.line, n.pos, types.Tadt, nil, nil)
		t.tparams = n.aux
		t.tbody = n.right
		d.ty = t
		t.decl = d
		return
	}
	t := stype(n.right)
	if ph != nil && t != ph && t.kind == types.Tadt {
		ph.ids = t.ids
		ph.ok |= t.ok & types.OKverify
		ph.line = t.line
		ph.pos = t.pos
		ph.ok &= ~(types.OKsized | types.OKclass)
		ph.size = 0
		t = ph
	}
	if n.right.op == types.Otpick {
		var tags ref types.Decl
		var last ref types.Decl
		ntag := 0
		for p := n.right.left; p != nil; p = p.right {
			tg := seqitem(p)
			tag := types.mkdecl(tg.line, tg.pos, types.Dtag, nil)
			tag.sym = tg.left.sym
			tag.tag = ntag
			ntag++
			tag.ty = types.mktype(tg.line, tg.pos, types.Tadtpick, nil, nil)
			if tg.right != nil {
				fake := types.mkn(types.Otstruct, tg.right, nil)
				fake.line = n.right.line
				fake.pos = n.right.pos
				ft := stype(fake)
				tag.ty.ids = ft.ids
			}
			tag.ty.tof = t
			tag.ty.decl = tag
			tag.dot = d
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
	}
	d.ty = t
	t.decl = d
	types.sizetype(t)
	types.teqclass(t)
}

func vardec(n ref types.Node) {
	var t ref types.Type
	if n.right != nil {
		t = stype(n.right)
		types.sizetype(t)
	}
	if n.aux != nil {
		var it ref types.Type
		if n.aux.op == types.Ocomposite {
			it = compositefields(n.aux)
		} else {
			it = echk(n.aux)
		}
		if t == nil {
			t = it
		} else if assignable(t, it, n.aux) == 0 {
			nerror(n, sys.sprint("cannot initialize %s from %s", tp(t), tp(it)))
		}
	}
	if t == nil {
		nerror(n, "variable needs a type")
		t = terror
	}
	for names := n.left; names != nil; names = names.right {
		id := seqitem(names)
		d := types.mkdecl(id.line, id.pos, types.Dglobal, t)
		d.sym = id.sym
		d.init = n.aux
		if n.aux != nil && n.aux.op != types.Oconst {
			d.runinit = 1
		}
		d.dot = impdecl
		install(d)
		d.link = nil
		if moduledecls == nil {
			moduledecls = d
		} else {
			e := moduledecls
			for e.link != nil {
				e = e.link
			}
			e.link = d
		}
		if names.op != types.Oseq {
			break
		}
	}
}

func fndecl(n ref types.Node) {
	nm := n.left
	var recv ref types.Node
	fsym := nm.sym
	var bt ref types.Type
	if nm.op == types.Omethod {
		recv = nm.left
		fsym = nm.right.sym
	}
	if n.aux == nil {
		nerror(n, "function requires a body (interfaces belong in .ei files)")
		return
	}
	if n.right.aux != nil {
		if recv != nil {
			nerror(n, "generic methods not yet supported")
			return
		}
		d := types.mkdecl(n.line, n.pos, types.Dfn, nil)
		d.sym = fsym
		d.init = n
		d.tparams = n.right.aux
		d.dot = impdecl
		install(d)
		return
	}
	if recv != nil {
		rty := recv.right
		if rty.op == types.Otref {
			rty = rty.right
		}
		if rty.op == types.Otinst || rty.op == types.Oindex {
			if rty.left.op != types.Oname {
				nerror(n, "bad generic receiver type")
				return
			}
			btd := lookup(rty.left.sym)
			if btd == nil || btd.store != types.Dtype || btd.ty == nil || btd.ty.tparams == nil {
				nerror(n, sys.sprint("%s is not a generic type", rty.left.sym))
				return
			}
			d := types.mkdecl(n.line, n.pos, types.Dfn, nil)
			d.sym = fsym
			d.init = n
			d.tparams = rty.right
			d.dot = btd
			d.link = btd.ty.methtmpl
			btd.ty.methtmpl = d
			return
		}
	}
	rawfn = 1
	t := stype(n.right)
	rawfn = 0
	if recv != nil {
		rt := stype(recv.right)
		bt = rt
		if bt.kind == types.Tref {
			bt = bt.tof
		}
		if bt.kind != types.Tadt {
			nerror(n, sys.sprint("receiver type must be a struct or ref struct, not %s", tp(rt)))
			return
		}
		rd := types.mkdecl(recv.left.line, recv.left.pos, types.Darg, rt)
		rd.sym = recv.left.sym
		rd.implicit = 1
		rd.next = t.ids
		t.ids = rd
	}
	t.ok |= types.OKverify
	types.sizetype(t)
	for dd := t.ids; dd != nil; dd = dd.next {
		types.sizetype(dd.ty)
	}
	types.sizetype(t.tof)
	d := types.mkdecl(n.line, n.pos, types.Dfn, t)
	d.sym = fsym
	d.init = n
	d.offset = types.idoffsets(t.ids, types.MaxTemp, types.IBY2WD)
	if recv != nil {
		d.dot = bt.decl
		d.link = bt.meths
		bt.meths = d
	} else {
		d.dot = impdecl
		install(d)
	}
	addfn(d)
	if d.sym == "init" {
		entrydecl = d
	}
}

func check(tree ref types.Node, file string) int {
	infile = file
	nerrors = 0
	if tree == nil || tree.op != types.Omodule {
		return 0
	}
	types.typeinit()
	tint = types.basic(types.Tint)
	tbig = types.basic(types.Tbig)
	tbyte = types.basic(types.Tbyte)
	treal = types.basic(types.Treal)
	tstring = types.basic(types.Tstring)
	tany = types.basic(types.Tany)
	tnone = types.basic(types.Tnone)
	terror = types.basic(types.Terror)
	for i := 0; i < HashSize; i++ {
		binds[i] = nil
	}
	fns = nil
	nfns = 0
	entrydecl = nil
	imports = nil
	moduledecls = nil
	scope = 0
	curclosure = nil
	nclosures = 0
	tinstdepth = 0
	modname = tree.left.sym
	pushscope()
	declbuiltin("int", tint)
	declbuiltin("big", tbig)
	declbuiltin("byte", tbyte)
	declbuiltin("real", treal)
	declbuiltin("string", tstring)
	nildecl = types.mkdecl(0, 0, types.Dglobal, tany)
	nildecl.sym = "nil"
	install(nildecl)
	pushscope()
	impdecl = types.mkdecl(tree.line, tree.pos, types.Dtype, nil)
	impdecl.sym = modname
	impdecl.ty = types.mktype(tree.line, tree.pos, types.Tmodule, nil, nil)
	impdecl.ty.decl = impdecl
	for n := tree.right; n != nil; n = n.right {
		decl := seqitem(n)
		if decl.op == types.Otypedecl && decl.aux == nil && decl.right != nil && (decl.right.op == types.Otstruct || decl.right.op == types.Otpick) {
			d := types.mkdecl(decl.line, decl.pos, types.Dtype, types.mktype(decl.line, decl.pos, types.Tadt, nil, nil))
			d.sym = decl.left.sym
			d.dot = impdecl
			d.ty.decl = d
			install(d)
			decl.decl = d
		}
		if n.op != types.Oseq {
			break
		}
	}
	for n := tree.right; n != nil; n = n.right {
		decl := seqitem(n)
		match decl.op {
		case types.Oimport:
			importchk(decl)
		case types.Ofndecl:
			fndecl(decl)
		case types.Ocondecl:
			t := echk(decl.right)
			if decl.right.op != types.Oconst {
				nerror(decl, "constant expression required")
			} else {
				d := types.mkdecl(decl.line, decl.pos, types.Dconst, t)
				d.sym = decl.left.sym
				d.init = decl.right
				install(d)
			}
		case types.Ovardecl:
			vardec(decl)
		case types.Otypedecl:
			typedec(decl)
		default:
			nerror(decl, sys.sprint("unsupported declaration %s", types.opname(decl.op)))
		}
		if n.op != types.Oseq {
			break
		}
	}
	nerrors += iface.ifaceerrors()
	if nerrors != 0 {
		return nerrors
	}
	for i := 0; i < nfns; i++ {
		if fns[i].checked != 0 {
			continue
		}
		fnchk(fns[i])
	}
	impdecl.ty.ids = nil
	var last ref types.Decl
	for i := 0; i < nfns; i++ {
		fns[i].next = nil
		if last == nil {
			impdecl.ty.ids = fns[i]
		} else {
			last.next = fns[i]
		}
		last = fns[i]
	}
	// the module's own interface is its module declaration: the
	// variables it declares are checked against the implementation
	// and exported as the .mp record (check.c)
	own := iface.readownface(impdecl.sym, infile)
	if own != nil {
		for id := own.ty.ids; id != nil; id = id.next {
			if id.store != types.Dglobal {
				continue
			}
			d := lookup(id.sym)
			if d == nil || d.store != types.Dglobal || d.dot != impdecl || d.importid != nil {
				errorat(iface.ownfacepath(), id.line, sys.sprint("interface declares variable %s, which module %s does not define", id.sym, impdecl.sym))
				continue
			}
			d.next = nil
			if last == nil {
				impdecl.ty.ids = d
			} else {
				last.next = d
			}
			last = d
		}
	}
	types.sizetype(impdecl.ty)
	types.teqclass(impdecl.ty)
	if own != nil {
		for id := own.ty.ids; id != nil; id = id.next {
			if id.store != types.Dglobal {
				continue
			}
			d := lookup(id.sym)
			if d == nil || d.store != types.Dglobal || d.dot != impdecl || d.importid != nil {
				continue
			}
			if types.sign(d) != types.sign(id) {
				errorat(iface.ownfacepath(), id.line, sys.sprint("variable %s is %s in the interface but %s in module %s", id.sym, tp(id.ty), tp(d.ty), impdecl.sym))
			}
		}
	}
	if impdecl.ty.tof != nil {
		impdecl.ty.tof.linkall = 1
	}
	types.modrefable(impdecl.ty)
	if own != nil {
		types.modrefable(own.ty)
		// and its functions and methods (check.c)
		for id := own.ty.ids; id != nil; id = id.next {
			if id.store != types.Dfn || id.tparams != nil {
				continue
			}
			if id.dot != nil && id.dot != own {
				td := lookup(id.dot.sym)
				if td == nil || td.store != types.Dtype || td.ty == nil || td.ty.kind != types.Tadt {
					errorat(iface.ownfacepath(), id.line, sys.sprint("interface declares method %s.%s, but module %s has no struct %s", id.dot.sym, id.sym, impdecl.sym, id.dot.sym))
					continue
				}
				d := td.ty.meths
				for d != nil && d.sym != id.sym {
					d = d.link
				}
				if d == nil {
					errorat(iface.ownfacepath(), id.line, sys.sprint("interface declares method %s.%s, which module %s does not define", id.dot.sym, id.sym, impdecl.sym))
					continue
				}
				if d.tparams == nil && types.sign(d) != types.sign(id) {
					errorat(iface.ownfacepath(), id.line, sys.sprint("method %s.%s is %s in the interface but %s in module %s", id.dot.sym, id.sym, tp(id.ty), tp(d.ty), impdecl.sym))
				}
				continue
			}
			d := lookup(id.sym)
			if d == nil || d.store != types.Dfn || d.dot != impdecl {
				errorat(iface.ownfacepath(), id.line, sys.sprint("interface declares function %s, which module %s does not define", id.sym, impdecl.sym))
				continue
			}
			if d.tparams == nil && types.sign(d) != types.sign(id) {
				errorat(iface.ownfacepath(), id.line, sys.sprint("function %s is %s in the interface but %s in module %s", id.sym, tp(id.ty), tp(d.ty), impdecl.sym))
			}
		}
	}
	return nerrors
}
