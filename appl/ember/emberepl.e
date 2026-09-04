module Emberepl

// emberepl: an Ember read-eval-print loop.  each line is compiled
// into a module of its own -- the declarations entered so far, then
// an init() running the statements entered so far -- which is loaded
// and run.  the earlier statements run again every time, so their
// output is written to /dev/null and only the newest line's output
// reaches the terminal.
//
//	emberepl [-I dir] [file ...]
//
// with files, the lines are read from them rather than the terminal,
// which is how the tests drive it.

import sys "sys"
import draw "draw"
import bufio "bufio"
import types "types"
import parse "parse"
import check "check"
import com "com"
import replline "replline"

const Tmpsrc = "/tmp/emberepl.e"
const Tmpdis = "/tmp/emberepl.dis"

type Line struct {
	text string
	decl int
}

var lines []ref Line
var incdirs list string

func isdecl(s string) int {
	for _, w := range []string{"import ", "type ", "func ", "const ", "var "} {
		if len(s) >= len(w) && s[0:len(w)] == w {
			return 1
		}
	}
	return 0
}

func trim(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i++
	}
	j := len(s)
	for j > i && (s[j - 1] == ' ' || s[j - 1] == '\t' || s[j - 1] == '\n') {
		j--
	}
	return s[i:j]
}

// the source for the session as it stands, with the newest line
// either printed as a value or run as a statement
func source(last string, asvalue int) string {
	b := ref Builder{}
	b.puts("module Replline\n\n")
	b.puts("import sys \"sys\"\n")
	b.puts("import draw \"draw\"\n")
	for _, l := range lines {
		if l.decl != 0 {
			b.puts(l.text)
			b.putc('\n')
		}
	}
	b.puts("\nfunc init(ctxt ref draw.Context, args list string) {\n")
	b.puts("\treplnull := sys.open(\"/dev/null\", sys.OWRITE)\n")
	b.puts("\treplout := sys.fildes(1)\n")
	b.puts("\tif replnull != nil {\n\t\tsys.dup(replnull.fd, 1)\n\t}\n")
	n := 0
	for _, l := range lines {
		if l.decl == 0 {
			b.puts("\t")
			b.puts(l.text)
			b.putc('\n')
			n++
		}
	}
	b.puts("\tsys.dup(replout.fd, 1)\n")
	if last != "" {
		if asvalue != 0 {
			b.puts("\tsys.print(\"%s\\n\", string(")
			b.puts(last)
			b.puts("))\n")
		} else {
			b.puts("\t")
			b.puts(last)
			b.putc('\n')
		}
	}
	b.puts("}\n")
	return b.string()
}

func write(path string, text string) int {
	fd := sys.create(path, sys.OWRITE, 0666)
	if fd == nil {
		return 0
	}
	a := []byte(text)
	if sys.write(fd, a, len(a)) != len(a) {
		return 0
	}
	return 1
}

// compile the session, quietly: the compiler writes its errors to
// standard error, which the caller redirects when it is only trying.
// every line gets fresh instances of the compiler's modules, since
// they are written for one compilation and keep state in globals
func build(text string) int {
	if write(Tmpsrc, text) == 0 {
		return 0
	}
	ty := load Types types.PATH
	ps := load Parse parse.PATH
	ck := load Check check.PATH
	cm := load Com com.PATH
	if ty == nil || ps == nil || ck == nil || cm == nil {
		sys.fprint(sys.fildes(2), "emberepl: cannot load the compiler: %r\n")
		return 0
	}
	ck.usetypes(ty)
	cm.usetypes(ty)
	cm.usecheck(ck)
	for l := incdirs; l != nil; l = tl(l) {
		ck.addincpath(hd(l))
	}
	tree := ps.parse(Tmpsrc)
	if tree == nil || ps.errors() != 0 {
		return 0
	}
	if ck.check(tree, Tmpsrc) != 0 {
		return 0
	}
	return cm.modcom(Tmpsrc, Tmpdis) == 0
}

func run() {
	m := load Replline Tmpdis
	if m == nil {
		sys.fprint(sys.fildes(2), "emberepl: cannot load the compiled line: %r\n")
		return
	}
	m.init(nil, nil)
}

func quiet() ref sys.FD {
	e := sys.fildes(2)
	null := sys.open("/dev/null", sys.OWRITE)
	if null != nil {
		sys.dup(null.fd, 2)
	}
	return e
}

func loud(e ref sys.FD) {
	if e != nil {
		sys.dup(e.fd, 2)
	}
}

func eval(text string) {
	if text == "" {
		return
	}
	if isdecl(text) != 0 {
		lines = append(lines, ref Line{text: text, decl: 1})
		src := source("", 0)
		if build(src) == 0 {
			lines = lines[0:len(lines) - 1]
			return
		}
		return
	}
	// an expression prints its value; anything else runs as a statement
	e := quiet()
	ok := build(source(text, 1))
	loud(e)
	if ok == 0 {
		if build(source(text, 0)) == 0 {
			return
		}
		lines = append(lines, ref Line{text: text, decl: 0})
		run()
		return
	}
	run()
}

func init(ctxt ref draw.Context, args list string) {
	var files list string
	l := args
	if l != nil {
		l = tl(l)
	}
	for ; l != nil; l = tl(l) {
		if hd(l) == "-I" && tl(l) != nil {
			l = tl(l)
			incdirs = hd(l) :: incdirs
			continue
		}
		files = hd(l) :: files
	}
	incdirs = "/ember/module" :: incdirs
	if files == nil {
		bio := bufio.fopen(sys.fildes(0), bufio.OREAD)
		for {
			sys.print("; ")
			s := bio.gets('\n')
			if s == nil {
				break
			}
			eval(trim(s))
		}
		sys.print("\n")
		return
	}
	var r list string
	for ; files != nil; files = tl(files) {
		r = hd(files) :: r
	}
	for ; r != nil; r = tl(r) {
		bio := bufio.open(hd(r), bufio.OREAD)
		if bio == nil {
			sys.fprint(sys.fildes(2), "emberepl: cannot open %s: %r\n", hd(r))
			continue
		}
		for {
			s := bio.gets('\n')
			if s == nil {
				break
			}
			eval(trim(s))
		}
	}
}
