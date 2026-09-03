module Emberc

import sys "sys"
import draw "draw"
import types "types"
import parse "parse"
import check "check"
import com "com"

// the self-hosted ember compiler's driver: parse, check, lower, write.
//
//	emberc [-I dir] [-o out.dis] file.e
//
// the built-in module directory is searched after every -I one.

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
		files = hd(l) :: files
	}
	check.addincpath("/ember/module")
	if files == nil {
		sys.fprint(sys.fildes(2), "usage: emberc [-I dir] [-o out.dis] file.e\n")
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
		tree := parse.parse(file)
		if tree == nil || parse.errors() != 0 {
			failed++
			continue
		}
		if check.check(tree, file) != 0 {
			failed++
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
