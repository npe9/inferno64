module Emberc

import sys "sys"
import draw "draw"
import types "types"
import parse "parse"
import check "check"
import com "com"
import fmt "emberfmt"
import ifacegen "ifacegen"

// the self-hosted ember compiler's driver: parse, check, lower, write.
//
//	emberc [-F] [-i] [-t] [-I dir] [-o out.dis] file.e
//
// the built-in module directory is searched after every -I one.
// -F prints the source formatted, -i its derived interface file, -t
// compiles a unit test with a synthesized init (ember/main.c's).

const Oimport = types.Oimport
const Ofndecl = types.Ofndecl
const Oname = types.Oname
const Oconst = types.Oconst
const Oseq = types.Oseq

func tname(line int, pos int, s string) ref types.Node {
	n := types.mkn(Oname, nil, nil)
	n.line = line
	n.pos = pos
	n.sym = s
	return n
}

func tsconst(line int, pos int, s string) ref types.Node {
	n := types.mkn(Oconst, nil, nil)
	n.line = line
	n.pos = pos
	n.sym = s
	n.flags |= types.NSTR
	return n
}

func tconst(line int, pos int, v int) ref types.Node {
	n := types.mkn(Oconst, nil, nil)
	n.line = line
	n.pos = pos
	n.val = big(v)
	return n
}

func at(n ref types.Node, line int, pos int) ref types.Node {
	n.line = line
	n.pos = pos
	return n
}

// .sys.print(args)
func tsprint(line int, pos int, args ref types.Node) ref types.Node {
	dot := at(types.mkbin(types.Odot, tname(line, pos, ".sys"), tname(line, pos, "print")), line, pos)
	dot.sym = dot.right.sym
	call := at(types.mkn(types.Ocall, dot, args), line, pos)
	return types.mkunary(types.Oexpr, call)
}

// "emberc -t": append
//
//	import .sys "sys"
//	func init() {
//		.failed := 0
//		try { test_a() } catch .e { .sys.print("FAIL test_a: %s\n", .e); .failed++ }
//		...
//		if .failed == 0 { .sys.print("PASS %d tests\n", n) } else { raise "fail:tests" }
//	}
//
// for every top-level "func test_xxx()" in the source, in order
func addtestmain(tree ref types.Node, file string) {
	line := tree.line
	pos := tree.pos
	var stmts ref types.Node
	n := 0
	for p := tree.right; p != nil; p = p.right {
		d := p
		if p.op == Oseq {
			d = p.left
		}
		if d.op == Ofndecl && d.left.op == Oname && len(d.left.sym) > 5 && d.left.sym[0:5] == "test_" && d.aux != nil {
			call := types.mkunary(types.Oexpr, types.mkn(types.Ocall, tname(line, pos, d.left.sym), nil))
			at(call, d.line, d.pos)
			tr := types.mkn(types.Otry, types.mkn(types.Oscope, call, nil), nil)	// "try" is a keyword
			tr.aux = tname(line, pos, ".e")
			msg := tsconst(line, pos, "FAIL ")
			msg = types.mkbin(types.Oadd, msg, tsconst(line, pos, d.left.sym))
			msg = types.mkbin(types.Oadd, msg, tsconst(line, pos, ": %s\n"))
			tr.right = types.mkn(types.Oscope, types.mkseq(tsprint(line, pos, types.rotater(types.mkseq(msg, tname(line, pos, ".e")))), types.mkunary(types.Oinc, tname(line, pos, ".failed"))), nil)
			at(tr, d.line, d.pos)
			stmts = types.mkseq(stmts, tr)
			n++
		}
		if p.op != Oseq {
			break
		}
	}
	if n == 0 {
		sys.fprint(sys.fildes(2), "emberc: -t: no test_ functions in %s\n", file)
		return
	}
	stmts = types.mkseq(types.mkbin(types.Odas, tname(line, pos, ".failed"), tconst(line, pos, 0)), stmts)
	cond := types.mkbin(types.Oeq, tname(line, pos, ".failed"), tconst(line, pos, 0))
	last := types.mkn(types.Oif, cond, types.mkn(types.Oscope, tsprint(line, pos, types.rotater(types.mkseq(tsconst(line, pos, "PASS %d tests\n"), tconst(line, pos, n)))), nil))
	last.aux = types.mkn(types.Oscope, types.mkunary(types.Oraise, tsconst(line, pos, "fail:tests")), nil)
	stmts = types.mkseq(stmts, last)
	body := types.mkn(types.Oscope, types.rotater(stmts), nil)
	// init(.ctxt ref .draw.Context, .args list string): the command signature emuinit links against
	ctx := types.mkbin(types.Odot, tname(line, pos, ".draw"), tname(line, pos, "Context"))
	ctx.sym = ctx.right.sym
	ctx = types.mkn(types.Otref, nil, ctx)
	params := types.mkseq(types.mkbin(types.Ofield, tname(line, pos, ".ctxt"), ctx), types.mkbin(types.Ofield, tname(line, pos, ".args"), types.mkn(types.Otlist, nil, tname(line, pos, "string"))))
	sig := types.mkn(types.Otfunc, types.rotater(params), nil)
	fn := types.mkn(Ofndecl, tname(line, pos, "init"), sig)
	fn.aux = body
	at(fn, line, pos)
	imp := at(types.mkn(Oimport, tname(line, pos, ".sys"), tname(line, pos, "sys")), line, pos)
	imp2 := at(types.mkn(Oimport, tname(line, pos, ".draw"), tname(line, pos, "draw")), line, pos)
	tree.right = types.rotater(types.mkseq(types.mkseq(types.mkseq(imp2, imp), tree.right), fn))
}

func defout(in string) string {
	b := []byte(in)
	dot := -1
	for i := 0; i < len(b); i++ {
		if b[i] == byte('.') {
			dot = i
		} else if b[i] == byte('/') {
			dot = -1
		}
	}
	if dot < 0 {
		return in + ".dis"
	}
	return string(b[0:dot]) + ".dis"
}

func init(ctxt ref draw.Context, argv list string) {
	var files list string
	outarg := ""
	fmtsrc := 0
	geniface := 0
	testmain := 0
	l := argv
	if l != nil {
		l = tl(l)
	}
	for ; l != nil; l = tl(l) {
		if hd(l) == "-I" && tl(l) != nil {
			l = tl(l)
			check.addincpath(hd(l))
			continue
		}
		if hd(l) == "-o" && tl(l) != nil {
			l = tl(l)
			outarg = hd(l)
			continue
		}
		if hd(l) == "-F" {
			fmtsrc = 1
			continue
		}
		if hd(l) == "-i" {
			geniface = 1
			continue
		}
		if hd(l) == "-t" {
			testmain = 1
			continue
		}
		files = hd(l) :: files
	}
	check.addincpath("/ember/module")
	if files == nil {
		sys.fprint(sys.fildes(2), "usage: emberc [-F] [-i] [-t] [-I dir] [-o out.dis] file.e\n")
		raise "fail:usage"
	}
	var r list string
	for ; files != nil; files = tl(files) {
		r = hd(files) :: r
	}
	failed := 0
	for ; r != nil; r = tl(r) {
		file := hd(r)
		check.usetypes(types)
		com.usetypes(types)
		com.usecheck(check)
		ifacegen.usecheck(check)
		if fmtsrc != 0 {
			parse.setfmt()
		}
		tree := parse.parse(file)
		if tree == nil || parse.errors() != 0 {
			failed++
			continue
		}
		if fmtsrc != 0 {
			fmt.print(1, tree, parse.comments(), parse.ncomments())
			continue
		}
		if testmain != 0 {
			addtestmain(tree, file)
		}
		if check.check(tree, file) != 0 {
			failed++
			continue
		}
		if geniface != 0 {
			ifacegen.ifacegen(tree, 1)
			continue
		}
		out := outarg
		if out == "" {
			out = defout(file)
		}
		if com.modcom(file, out) != 0 {
			failed++
		}
	}
	if failed != 0 {
		raise "fail:errors"
	}
}
