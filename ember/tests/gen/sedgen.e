module Sedgen

// appl/cmd/sed.b in Ember: the partial sed borrowed from Plan 9.
//
// Ember picks carry no fields shared by every tag, so sed.b's Sedcom
// (four common fields plus a pick) is a Sedcom struct holding a Cmd
// pick; "tagof x != tagof Addr.None" is isnone(); the "match" helper
// is rematch, since match is Ember's keyword.  "0 to 9" case ranges
// are spelled out.

import sys "sys"
import draw "draw"
import arg "arg"
import bufio "bufio"
import str "string"
import regex "regex"

type Addr pick {
	None()
	Dollar()
	Line(line int)
	Regex(re ref regex.Arena)
}

type Cmd pick {
	S(gfl bool, pfl int, re ref regex.Arena, b ref bufio.Iobuf, rhs string)
	D()
	CD()
	P()
	Q()
	EQ()
	G()
	CG()
	H()
	CH()
	N()
	CN()
	X()
	CP()
	L()
	A(text string)
	C(text string)
	I(text string)
	R(filename string)
	W(b ref bufio.Iobuf)
	Y(mp list (int, int))
	B(lab string)
	T(lab string)
	Lab(lab string)
}

type Sedcom struct {
	ad1 ref Addr
	ad2 ref Addr
	negfl bool
	active int
	cmd ref Cmd
}

func mk(ad1 ref Addr, ad2 ref Addr, negfl bool, cmd ref Cmd) ref Sedcom {
	return ref Sedcom{ad1: ad1, ad2: ad2, negfl: negfl, active: 0, cmd: cmd}
}

func isnone(a ref Addr) bool {
	match a {
	case Addr.None:
		return true
	}
	return false
}

var dflag = false
var nflag = false
var gflag = false
var sflag = false

var delflag = 0
var dolflag = 0
var fhead = 0
var files list string
var fout ref bufio.Iobuf
var infile ref bufio.Iobuf
var jflag = false
var lastregex ref regex.Arena
var linebuf string
var filename = ""
var lnum = 0
var peekc = 0

var holdsp = ""
var patsp = ""

var cmds list ref Sedcom
var appendlist list ref Sedcom
var bufioflush list ref bufio.Iobuf

func init(ctxt ref draw.Context, args list string) {
	arg.init(args)

	compfl := 0
	for {
		c := arg.opt()
		if c == 0 {
			break
		}
		match c {
		case 'n':
			nflag = true
		case 'g':
			gflag = true
		case 'e':
			s := arg.arg()
			if s == nil {
				usage()
			}
			filename = ""
			cmds = compile(bufio.sopen(s + "\n"), cmds)
			compfl = 1
		case 'f':
			filename = arg.arg()
			if filename == nil {
				usage()
			}
			b := bufio.open(filename, bufio.OREAD)
			if b == nil {
				fatal(sys.sprint("couldn't open '%s': %r", filename))
			}
			cmds = compile(b, cmds)
			compfl = 1
		case 'd':
			dflag = true
		default:
			usage()
		}
	}
	args = arg.argv()
	if compfl == 0 {
		if len(args) == 0 {
			fatal("missing pattern")
		}
		filename = ""
		cmds = compile(bufio.sopen(hd(args) + "\n"), cmds)
		args = tl(args)
	}

	// reverse command list, we could compile addresses here if required
	var l list ref Sedcom
	for p := cmds; p != nil; p = tl(p) {
		l = hd(p) :: l
	}
	cmds = l

	// add files to file list (and reverse to get in right order)
	var f list string
	if len(args) == 0 {
		f = "" :: f
	} else {
		for ; len(args) != 0; args = tl(args) {
			f = hd(args) :: f
		}
	}
	for ; f != nil; f = tl(f) {
		files = hd(f) :: files
	}

	fout = bufio.fopen(sys.fildes(1), bufio.OWRITE)
	if fout == nil {
		fatal(sys.sprint("couldn't buffer stdout: %r"))
	}
	bufioflush = fout :: bufioflush
	lnum = 0
	execute(cmds)
	exits(nil)
}

var depth = 0
const maxdepth = 20
var cmdend = [maxdepth]string
var cmdcnt = [maxdepth]int

func compile(b ref bufio.Iobuf, l list ref Sedcom) list ref Sedcom {
	lnum = 1

nextline:
	for {
		var err int
		err, linebuf = getline(b)
		if err < 0 {
			break
		}

		s := linebuf

		for {
			var rep ref Sedcom
			var ad1, ad2 ref Addr
			negfl := false

			if s != "" {
				s = str.drop(s, " \t;")
			}

			if s == "" || s[0] == '#' {
				continue nextline
			}

			// read addresses
			s, ad1 = address(s)
			if isnone(ad1) {
				ad2 = ref Addr.None{}
			} else {
				if s != "" && (s[0] == ',' || s[0] == ';') {
					s, ad2 = address(s[1:])
				} else {
					ad2 = ref Addr.None{}
				}
			}

			s = str.drop(s, " \t")

			if s != "" && str.in(s[0], "!") != 0 {
				negfl = true
				s = str.drop(s, "!")
			}
			s = str.drop(s, " \t")
			if s == "" {
				break
			}
			c := s[0]
			s = s[1:]

			// mop up commands that got two addresses but only want one.
			match c {
			case 'a', 'c', 'q', '=', 'i':
				if !isnone(ad2) {
					fatal(sys.sprint("only one address allowed:  '%s'", linebuf))
				}
			}

			match c {
			default:
				fatal(sys.sprint("unrecognised command: '%s' (%c)", linebuf, c))
			case 'a':
				if s != "" && s[0] == '\\' {
					s = s[1:]
				}
				if s == "" || s[0] != '\n' {
					fatal("unexpected characters in a command: " + s)
				}
				rep = mk(ad1, ad2, negfl, ref Cmd.A{text: s[1:]})
				s = ""
			case 'c':
				if s != "" && s[0] == '\\' {
					s = s[1:]
				}
				if s == "" || s[0] != '\n' {
					fatal("unexpected characters in c command: " + s)
				}
				rep = mk(ad1, ad2, negfl, ref Cmd.C{text: s[1:]})
				s = ""
			case 'i':
				if s != "" && s[0] == '\\' {
					s = s[1:]
				}
				if s == "" || s[0] != '\n' {
					fatal("unexpected characters in i command: " + s)
				}
				rep = mk(ad1, ad2, negfl, ref Cmd.I{text: s[1:]})
				s = ""
			case 'r':
				s = str.drop(s, " \t")
				rep = mk(ad1, ad2, negfl, ref Cmd.R{filename: s})
				s = ""
			case 'w':
				if s != "" {
					s = str.drop(s, " \t")
				}
				if s == "" {
					fatal("no filename in w command: " + linebuf)
				}
				bo := bufio.open(s, bufio.OWRITE)
				if bo == nil {
					bo = bufio.create(s, bufio.OWRITE, 0666)
				}
				if bo == nil {
					fatal(sys.sprint("can't create output file: '%s'", s))
				}
				bufioflush = bo :: bufioflush
				rep = mk(ad1, ad2, negfl, ref Cmd.W{b: bo})
				s = ""
			case 'd':
				rep = mk(ad1, ad2, negfl, ref Cmd.D{})
			case 'D':
				rep = mk(ad1, ad2, negfl, ref Cmd.CD{})
			case 'p':
				rep = mk(ad1, ad2, negfl, ref Cmd.P{})
			case 'P':
				rep = mk(ad1, ad2, negfl, ref Cmd.CP{})
			case 'q':
				rep = mk(ad1, ad2, negfl, ref Cmd.Q{})
			case '=':
				rep = mk(ad1, ad2, negfl, ref Cmd.EQ{})
			case 'g':
				rep = mk(ad1, ad2, negfl, ref Cmd.G{})
			case 'G':
				rep = mk(ad1, ad2, negfl, ref Cmd.CG{})
			case 'h':
				rep = mk(ad1, ad2, negfl, ref Cmd.H{})
			case 'H':
				rep = mk(ad1, ad2, negfl, ref Cmd.CH{})
			case 'n':
				rep = mk(ad1, ad2, negfl, ref Cmd.N{})
			case 'N':
				rep = mk(ad1, ad2, negfl, ref Cmd.CN{})
			case 'x':
				rep = mk(ad1, ad2, negfl, ref Cmd.X{})
			case 'l':
				rep = mk(ad1, ad2, negfl, ref Cmd.L{})
			case 'y':
				if s == "" {
					fatal("expected args: " + linebuf)
				}
				seof := s[0:1]
				s = s[1:]
				if s == "" {
					fatal("no lhs: " + linebuf)
				}
				lhs, s2 := str.splitl(s, seof)
				if s2 == "" {
					fatal("no lhs terminator: " + linebuf)
				}
				s2 = s2[1:]
				rhs, s4 := str.splitl(s2, seof)
				if s4 == "" {
					fatal("no rhs: " + linebuf)
				}
				s = s4[1:]
				if len(lhs) != len(rhs) {
					fatal("y command needs same length sets: " + linebuf)
				}
				var mp list (int, int)
				for i := range lhs {
					mp = (lhs[i], rhs[i]) :: mp
				}
				rep = mk(ad1, ad2, negfl, ref Cmd.Y{mp: mp})
			case 's':
				seof := s[0:1]
				var re ref regex.Arena
				re, s = recomp(s)
				var rhs string
				s, rhs = compsub(seof + s)

				gfl := gflag
				pfl := 0

				if s != "" && s[0] == 'g' {
					gfl = true
					s = s[1:]
				}
				if s != "" && s[0] == 'p' {
					pfl = 1
					s = s[1:]
				}
				if s != "" && s[0] == 'P' {
					pfl = 2
					s = s[1:]
				}

				var b ref bufio.Iobuf
				if s != "" && s[0] == 'w' {
					s = s[1:]
					if s != "" {
						s = str.drop(s, " \t")
					}
					if s == "" {
						fatal("no filename in s with w: " + linebuf)
					}
					b = bufio.open(s, bufio.OWRITE)
					if b == nil {
						b = bufio.create(s, bufio.OWRITE, 0666)
					}
					if b == nil {
						fatal(sys.sprint("can't create output file: '%s'", s))
					}
					bufioflush = b :: bufioflush
					s = ""
				}
				rep = mk(ad1, ad2, negfl, ref Cmd.S{gfl: gfl, pfl: pfl, re: re, b: b, rhs: rhs})
			case ':':
				if s != "" {
					s = str.drop(s, " \t")
				}
				lab, s1 := str.splitl(s, " \t;#")
				s = s1
				if lab == "" {
					fatal(sys.sprint("null label: '%s'", linebuf))
				}
				if findlabel(lab) {
					fatal(sys.sprint("duplicate label: '%s'", lab))
				}
				rep = mk(ad1, ad2, negfl, ref Cmd.Lab{lab: lab})
			case 'b', 't':
				if s != "" {
					s = str.drop(s, " \t")
				}
				lab, s1 := str.splitl(s, " \t;#")
				s = s1
				if c == 'b' {
					rep = mk(ad1, ad2, negfl, ref Cmd.B{lab: lab})
				} else {
					rep = mk(ad1, ad2, negfl, ref Cmd.T{lab: lab})
				}
			case '{':
				// replace { with branch to }.
				lab := mklab(depth)
				depth++
				rep = mk(ad1, ad2, !negfl, ref Cmd.B{lab: lab})
				s = ";" + s
			case '}':
				if !isnone(ad1) {
					fatal("did not expect address:" + linebuf)
				}
				depth--
				if depth < 0 {
					fatal("too many }'s: " + linebuf)
				}
				lab := mklab(depth)
				cmdcnt[depth]++
				rep = mk(ad1, ad2, negfl, ref Cmd.Lab{lab: lab})
				s = ";" + s
			}

			l = rep :: l
			if !(s != nil && str.in(s[0], ";{}") != 0) {
				break
			}
		}

		if s != nil {
			fatal("leftover junk: " + s)
		}
	}
	return l
}

func findlabel(lab string) bool {
	for l := cmds; l != nil; l = tl(l) {
		match hd(l).cmd {
		case Cmd.Lab(x):
			if x == lab {
				return true
			}
		}
	}
	return false
}

func mklab(depth int) string {
	return "_" + string(cmdcnt[depth]) + "_" + string(depth)
}

func (c ref Sedcom) command() {
	match c.cmd {
	case Cmd.S(gfl, pfl, re, b, rhs):
		var m bool
		m, patsp = substitute(gfl, re, rhs, patsp)
		if m {
			if pfl == 1 {
				fout.puts(patsp + "\n")
			} else if pfl != 0 {
				var l string
				l, patsp = str.splitl(patsp, "\n")
				fout.puts(l + "\n")
			}
			if b != nil {
				b.puts(patsp + "\n")
			}
		}
	case Cmd.P:
		fout.puts(patsp + "\n")
	case Cmd.CP:
		s, _ := str.splitl(patsp, "\n")
		fout.puts(s + "\n")
	case Cmd.A(text):
		appendlist = c :: appendlist
	case Cmd.R(filename):
		appendlist = c :: appendlist
	case Cmd.C(text):
		delflag++
		if c.active == 1 {
			fout.puts(text + "\n")
		}
	case Cmd.I(text):
		fout.puts(text + "\n")
	case Cmd.W(b):
		b.puts(patsp + "\n")
	case Cmd.G:
		patsp = holdsp
	case Cmd.CG:
		patsp += holdsp
	case Cmd.H:
		holdsp = patsp
	case Cmd.CH:
		holdsp += patsp
	case Cmd.X:
		holdsp, patsp = patsp, holdsp
	case Cmd.Y(mp):
		// yes this is O(N²).
		for i := range patsp {
			for h := mp; h != nil; h = tl(h) {
				s, d := hd(h)
				if patsp[i] == s {
					patsp[i] = d
				}
			}
		}
	case Cmd.D:
		delflag++
	case Cmd.CD:
		// loose upto \n.
		s1, s2 := str.splitl(patsp, "\n")
		if s2 == nil {
			patsp = s1
		} else if len(s2) > 1 {
			patsp = s2[1:]
		} else {
			patsp = ""
		}
		jflag = true
	case Cmd.Q:
		if !nflag {
			fout.puts(patsp + "\n")
		}
		arout()
		exits(nil)
	case Cmd.N:
		if !nflag {
			fout.puts(patsp + "\n")
		}
		arout()
		var n int
		patsp, n = gline()
		if n < 0 {
			delflag++
		}
	case Cmd.CN:
		arout()
		ns, n := gline()
		if n < 0 {
			delflag++
		}
		patsp += "\n" + ns
	case Cmd.EQ:
		fout.puts(sys.sprint("%d\n", lnum))
	case Cmd.Lab(lab):
		// labels don't do anything.
		_ = lab
	case Cmd.B(lab):
		jflag = true
	case Cmd.T(lab):
		if sflag {
			sflag = false
			jflag = true
		}
	case Cmd.L:
		col := 0
		cc := 0
		for i := range patsp {
			s := ""
			cc = patsp[i]
			if cc >= 0x20 && cc < 0x7F && cc != '\n' {
				s[len(s)] = cc
			} else {
				s = trans(cc)
			}
			for j := range s {
				fout.putc(s[j])
				if col > 71 {
					fout.puts("\\\n")
					col = 0
				} else {
					col++
				}
			}
		}
		if cc == ' ' {
			fout.puts("\\n")
		}
		fout.putc('\n')
	default:
		fatal("unhandled command")
	}
}

func trans(ch int) string {
	match ch {
	case '\b':
		return "\\b"
	case '\n':
		return "\\n"
	case '\r':
		return "\\r"
	case '\t':
		return "\\t"
	case '\\':
		return "\\\\"
	default:
		return sys.sprint("\\u%.4ux", ch)
	}
}

func getline(b ref bufio.Iobuf) (int, string) {
	var w string

	lnum++

	for {
		c := b.getc()
		if c == bufio.EOF {
			break
		}
		r := c
		if r == '\\' {
			w[len(w)] = r
			c = b.getc()
			if c == bufio.EOF {
				break
			}
			r = c
		} else if r == '\n' {
			return 1, w
		}
		w[len(w)] = r
	}
	return -1, w
}

func address(s string) (string, ref Addr) {
	match s[0] {
	case '$':
		return s[1:], ref Addr.Dollar{}
	case '/':
		r, s1 := recomp(s)
		if r == nil {
			r = lastregex
		}
		if r == nil {
			fatal("First RE in address may not be null")
		}
		return s1, ref Addr.Regex{re: r}
	case '0', '1', '2', '3', '4', '5', '6', '7', '8', '9':
		lno, ls := str.toint(s, 10)
		if lno == 0 {
			fatal("line no 0 is illegal address")
		}
		return ls, ref Addr.Line{line: lno}
	default:
		return s, ref Addr.None{}
	}
}

func recomp(s string) (ref regex.Arena, string) {
	expbuf := ""

	seof := s[0]
	s = s[1:]
	if s[0] == seof {
		return nil, s[1:]	// //
	}

	c := s[0]
	s = s[1:]
	for {
		if c == 0 || c == '\n' {
			fatal("too much text: " + linebuf)
		}
		if c == '\\' {
			expbuf[len(expbuf)] = c
			c = s[0]
			s = s[1:]
			if c == 'n' {
				c = '\n'
			}
		}
		expbuf[len(expbuf)] = c
		c = s[0]
		s = s[1:]
		if c == seof {
			break
		}
	}

	r, err := regex.compile(expbuf, 1)
	if r == nil {
		fatal(sys.sprint("%s '%s'", err, expbuf))
	}

	lastregex = r

	return r, s
}

func compsub(s string) (string, string) {
	seof := s[0]
	rhs := ""
	i := 1
	for ; i < len(s); i++ {
		r := s[i]
		if r == seof {
			break
		}
		if r == '\\' {
			rhs[len(rhs)] = r
			i++
			if i >= len(s) {
				break
			}
			r = s[i]
		}
		rhs[len(rhs)] = r
	}
	if i >= len(s) {
		fatal(sys.sprint("no closing %c in replacement text: %s", seof, linebuf))
	}
	return s[i + 1:], rhs
}

// is c a branch, and to which label?
func branchlab(c ref Sedcom) (bool, string) {
	match c.cmd {
	case Cmd.B(lab):
		return true, lab
	case Cmd.T(lab):
		return true, lab
	}
	return false, ""
}

// the commands from the label lab on, or nil
func findlab(l list ref Sedcom, lab string) list ref Sedcom {
	for p := l; p != nil; p = tl(p) {
		match hd(p).cmd {
		case Cmd.Lab(x):
			if x == lab {
				return p
			}
		}
	}
	return nil
}

func execute(l list ref Sedcom) {
	for {
		var n int

		patsp, n = gline()
		if n < 0 {
			break
		}

cmdloop:
		for p := l; p != nil; {
			c := hd(p)
			if !c.executable() {
				p = tl(p)
				continue
			}

			c.command()

			if delflag != 0 {
				break
			}
			if jflag {
				jflag = false
				isbr, lab := branchlab(c)
				if isbr {
					p = findlab(l, lab)
					if p == nil {
						break cmdloop	// unmatched branch => end of script
					}
					continue cmdloop
				}
				// don't branch.
			} else {
				p = tl(p)
			}
		}
		if !nflag && delflag == 0 {
			fout.puts(patsp + "\n")
		}
		arout()
		delflag = 0
	}
}

func (c ref Sedcom) executable() bool {
	if c.active != 0 {
		if c.active == 1 {
			c.active = 2
		}
		match c.ad2 {
		case Addr.None:
			c.active = 0
		case Addr.Dollar:
			return !c.negfl
		case Addr.Line(line):
			if lnum <= line {
				if line == lnum {
					c.active = 0
				}
				return !c.negfl
			}
			c.active = 0
			return c.negfl
		case Addr.Regex(re):
			if rematch(re, patsp) {
				c.active = 0
			}
			return !c.negfl
		}
	}
	match c.ad1 {
	case Addr.None:
		return !c.negfl
	case Addr.Dollar:
		if dolflag != 0 {
			return !c.negfl
		}
	case Addr.Line(line):
		if line == lnum {
			c.active = 1
			return !c.negfl
		}
	case Addr.Regex(re):
		if rematch(re, patsp) {
			c.active = 1
			return !c.negfl
		}
	}
	return c.negfl
}

func arout() {
	var a list ref Sedcom

	for appendlist != nil {
		a = hd(appendlist) :: a
		appendlist = tl(appendlist)
	}

	for ; a != nil; a = tl(a) {
		match hd(a).cmd {
		case Cmd.A(text):
			fout.puts(text + "\n")
		case Cmd.R(filename):
			b := bufio.open(filename, bufio.OREAD)
			if b == nil {
				fatal(sys.sprint("couldn't open '%s'", filename))
			}
			for {
				c := b.getc()
				if c == bufio.EOF {
					break
				}
				fout.putc(c)
			}
			b.close()
		default:
			fatal("unexpected command on appendlist")
		}
	}
}

func rematch(re ref regex.Arena, s string) bool {
	return re != nil && regex.execute(re, s) != nil
}

func substitute(gfl bool, cre ref regex.Arena, rhs string, s string) (bool, string) {
	if !rematch(cre, s) {
		return false, s
	}
	sflag = true
	start := 0

	// Beware of infinite loops: 's/$/i/g', 's/a/aa/g', 's/^/a/g'
	for {
		m := regex.executese(cre, s, (start, len(s)), 1, 1)
		if m == nil {
			break
		}
		l, r := m[0]
		rep := ""
		for i := 0; i < len(rhs); i++ {
			if rhs[i] != '\\' || i + 1 == len(rhs) {
				if rhs[i] == '&' {
					rep += s[l:r]
				} else {
					rep[len(rep)] = rhs[i]
				}
			} else {
				i++
				match rhs[i] {
				case '0', '1', '2', '3', '4', '5', '6', '7', '8', '9':
					n := rhs[i] - '0'
					// elide if too big
					if n < len(m) {
						beg, end := m[n]
						rep += s[beg:end]
					}
				case 'n':
					rep[len(rep)] = '\n'
				default:
					rep[len(rep)] = rhs[i]
				}
			}
		}
		s = s[0:l] + rep + s[r:]
		start = l + len(rep)
		if r == l {
			start++
		}
		if !gfl {
			break
		}
	}
	return true, s
}

func gline() (string, int) {
	if infile == nil && opendatafile() < 0 {
		return nil, -1
	}

	sflag = false
	lnum++

	s := ""
	for {
		c := peekc
		if c == 0 {
			c = infile.getc()
		}
		for ; c != bufio.EOF; c = infile.getc() {
			if c == '\n' {
				peekc = infile.getc()
				if peekc == bufio.EOF {
					if fhead == 0 {
						dolflag = 1
					}
				}
				return s, 1
			}
			s[len(s)] = c
		}
		if len(s) != 0 {
			peekc = bufio.EOF
			if fhead == 0 {
				dolflag = 1
			}
			return s, 1
		}
		peekc = 0
		infile = nil
		if opendatafile() <= 0 {
			break
		}
	}
	infile = nil
	return nil, -1
}

func opendatafile() int {
	if files == nil {
		return -1
	}
	if hd(files) != nil {
		infile = bufio.open(hd(files), bufio.OREAD)
		if infile == nil {
			fatal(sys.sprint("can't open '%s'", hd(files)))
		}
	} else {
		infile = bufio.fopen(sys.fildes(0), bufio.OREAD)
		if infile == nil {
			fatal("can't buffer stdin")
		}
	}

	files = tl(files)
	return 1
}

func dbg(s string) {
	if dflag {
		sys.print("dbg: %s\n", s)
	}
}

func usage() {
	sys.fprint(stderr(), "usage: %s [-ngd] [-e expr] [-f file] [expr] [file...]\n",
		arg.progname())
	exits("usage")
}

func fatal(s string) {
	f := filename
	if f == nil {
		f = "<stdin>"
	}
	sys.fprint(stderr(), "%s:%d %s\n", f, lnum, s)
	exits("error")
}

func exits(e string) {
	for ; bufioflush != nil; bufioflush = tl(bufioflush) {
		hd(bufioflush).flush()
	}
	if e != nil {
		raise "fail:" + e
	}
	exit()
}

func stderr() ref sys.FD {
	return sys.fildes(2)
}
