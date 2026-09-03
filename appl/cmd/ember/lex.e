module Lex

import sys "sys"
import bufio "bufio"

// a port of ember/lex.c, function for function: the same character
// classes, the same go-style numbers, strings and escapes, the same
// automatic semicolons at newlines.  the source is read whole into
// a string and indexed by rune; getc() advances the column by the
// rune's byte length and getrune() by one, exactly as the C lexer's
// byte-wise Getc() and rune-wise getrune() do, so columns agree even
// past non-ASCII text.

const Beof = -1

const Eid = 256
const Econst = 257
const Erconst = 258
const Esconst = 259
const Eandand = 260
const Eoror = 261
const Eeq = 262
const Eneq = 263
const Eleq = 264
const Egeq = 265
const Elsh = 266
const Ersh = 267
const Ecomm = 268
const Edeclas = 269
const Einc = 270
const Edec = 271
const Eaddeq = 272
const Esubeq = 273
const Emuleq = 274
const Ediveq = 275
const Emodeq = 276
const Eandeq = 277
const Eoreq = 278
const Exoreq = 279
const Elsheq = 280
const Ersheq = 281
const Edots = 282
const Econs = 283
const Kbreak = 284
const Kcase = 285
const Kchan = 286
const Kconst = 287
const Kcontinue = 288
const Kdefault = 289
const Kelse = 290
const Kfor = 291
const Kfunc = 292
const Kif = 293
const Kimport = 294
const Kinterface = 295
const Klist = 296
const Kload = 297
const Kmatch = 298
const Kmodule = 299
const Knil = 300
const Kpick = 301
const Kref = 302
const Kreturn = 303
const Kspawn = 304
const Kstruct = 305
const Ktype = 306
const Kvar = 307
const Kalt = 308
const Kraise = 309

const Mlower = 1
const Mupper = 2
const Munder = 4
const Malpha = 7
const Mdigit = 8
const Mhex = 16

const Linestart = 0

type Tok struct {
	t int
	line int
	pos int
	sym string
	ival big
	rval real
	text string
}

type Lexer struct {
	file string
	src string
	at int
	eof int
	line int
	pos int
	lasttok int
	errors int
}

func open(file string) ref Lexer {
	f := bufio.open(file, bufio.OREAD)
	if f == nil {
		return nil
	}
	src := ""
	for {
		line := f.gets('\n')
		if line == nil {
			break
		}
		src += line
	}
	f.close()
	return ref Lexer{file: file, src: src, at: 0, eof: 0, line: 1, pos: Linestart, lasttok: 0, errors: 0}
}

func cmap(c int) int {
	if c < 0 {
		return 0
	}
	if c >= 256 {
		return Mlower
	}
	m := 0
	if c == '_' || c > 0xa0 {
		m |= Munder
	}
	if c >= 'A' && c <= 'Z' {
		m |= Mupper
	}
	if c >= 'a' && c <= 'z' {
		m |= Mlower
	}
	if (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f') {
		m |= Mhex
	}
	if c >= '0' && c <= '9' {
		m |= Mdigit
	}
	return m
}

func runelen(c int) int {
	if c < 0x80 {
		return 1
	}
	if c < 0x800 {
		return 2
	}
	if c < 0x10000 {
		return 3
	}
	return 4
}

func (lx ref Lexer) error(msg string) {
	lx.errors++
	sys.fprint(sys.fildes(2), "%s:%d: %s\n", lx.file, lx.line, msg)
}

// rune-wise read: one column per rune
func (lx ref Lexer) getrune() int {
	if lx.eof != 0 {
		return Beof
	}
	if lx.at >= len(lx.src) {
		// the C reader counts the column for the read that finds
		// the end too, so the eof token sits one past the last
		lx.eof = 1
		lx.pos++
		return Beof
	}
	c := lx.src[lx.at]
	lx.at++
	lx.pos++
	return c
}

func (lx ref Lexer) ungetrune() {
	if lx.eof != 0 {
		return
	}
	lx.at--
	lx.pos--
}

// byte-wise read: a column per UTF-8 byte, as the C lexer's Getc()
func (lx ref Lexer) getc() int {
	if lx.eof != 0 {
		return Beof
	}
	if lx.at >= len(lx.src) {
		lx.eof = 1
		lx.pos++
		return Beof
	}
	c := lx.src[lx.at]
	lx.at++
	lx.pos += runelen(c)
	return c
}

func (lx ref Lexer) ungetc() {
	if lx.eof != 0 {
		return
	}
	lx.at--
	lx.pos -= runelen(lx.src[lx.at])
}

func keyword(id string) int {
	match id {
	case "alt":
		return Kalt
	case "break":
		return Kbreak
	case "case":
		return Kcase
	case "chan":
		return Kchan
	case "const":
		return Kconst
	case "continue":
		return Kcontinue
	case "default":
		return Kdefault
	case "else":
		return Kelse
	case "for":
		return Kfor
	case "func":
		return Kfunc
	case "if":
		return Kif
	case "import":
		return Kimport
	case "interface":
		return Kinterface
	case "list":
		return Klist
	case "load":
		return Kload
	case "match":
		return Kmatch
	case "module":
		return Kmodule
	case "nil":
		return Knil
	case "pick":
		return Kpick
	case "raise":
		return Kraise
	case "ref":
		return Kref
	case "return":
		return Kreturn
	case "spawn":
		return Kspawn
	case "struct":
		return Kstruct
	case "type":
		return Ktype
	case "var":
		return Kvar
	}
	return Eid
}

func (lx ref Lexer) lexid(tok ref Tok, c int) int {
	id := ""
	for {
		id += sys.sprint("%c", c)
		c = lx.getrune()
		if c == Beof || (cmap(c) & (Malpha | Mdigit)) == 0 {
			lx.ungetrune()
			break
		}
	}
	tok.sym = id
	return keyword(id)
}

func digit(c int, base int) int {
	ck := cmap(c)
	if (ck & Mdigit) != 0 {
		c -= '0'
	} else if (ck & Mlower) != 0 {
		c = c - 'a' + 10
	} else if (ck & Mupper) != 0 {
		c = c - 'A' + 10
	} else {
		return -1
	}
	if c >= base {
		return -1
	}
	return c
}

// numeric literals in the go style: 123, 0x1f, 0o17, 0b101, 1.5,
// 1e9, 1.5e-3, .5
func (lx ref Lexer) lexnum(tok ref Tok, c int) int {
	buf := ""
	base := 10
	isreal := 0
	if c == '0' {
		c = lx.getc()
		if c == 'x' || c == 'X' {
			base = 16
			c = lx.getc()
		} else if c == 'o' || c == 'O' {
			base = 8
			c = lx.getc()
		} else if c == 'b' || c == 'B' {
			base = 2
			c = lx.getc()
		} else {
			lx.ungetc()
			c = '0'
		}
	}
	if c == '.' {
		isreal = 1
		buf += "."
		c = lx.getc()
	}
	for {
		if c == '_' {
			c = lx.getc()
			continue
		}
		if base == 10 && isreal == 0 && c == '.' {
			isreal = 1
			buf += "."
			c = lx.getc()
			continue
		}
		if base == 10 && (c == 'e' || c == 'E') {
			isreal = 1
			buf += sys.sprint("%c", c)
			c = lx.getc()
			if c == '+' || c == '-' {
				buf += sys.sprint("%c", c)
				c = lx.getc()
			}
			continue
		}
		dbase := base
		if base == 10 && isreal != 0 {
			dbase = 10
		}
		if digit(c, dbase) < 0 {
			break
		}
		buf += sys.sprint("%c", c)
		c = lx.getc()
	}
	lx.ungetc()
	if len(buf) == 0 {
		lx.error("malformed numeric constant")
		tok.ival = big(0)
		return Econst
	}
	if isreal != 0 {
		tok.rval = real(buf)
		tok.text = buf
		return Erconst
	}
	v := big(0)
	for i := 0; i < len(buf); i++ {
		v = v * big(base) + big(digit(buf[i], base))
	}
	tok.ival = v
	return Econst
}

func (lx ref Lexer) escchar() int {
	c := lx.getrune()
	if c == Beof {
		return Beof
	}
	if c == 'u' {
		v := 0
		for i := 0; i < 4; i++ {
			c = lx.getrune()
			if c == Beof || (cmap(c) & (Mdigit | Mhex)) == 0 {
				lx.error("malformed \\u escape sequence")
				lx.ungetrune()
				break
			}
			v = v * 16 + digit(c, 16)
		}
		return v
	}
	match c {
	case '\'':
		return '\''
	case '"':
		return '"'
	case '\\':
		return '\\'
	case 'a':
		return 7
	case 'b':
		return 8
	case 'f':
		return 12
	case 'n':
		return 10
	case 'r':
		return 13
	case 't':
		return 9
	case 'v':
		return 11
	case '0':
		return 0
	}
	lx.error(sys.sprint("unrecognized escape \\%c", c))
	return c
}

func (lx ref Lexer) lexstring(israw int) string {
	str := ""
	for {
		c := lx.getrune()
		if israw != 0 {
			if c == '`' {
				break
			}
			if c == Beof {
				lx.error("end of file in raw string constant")
				break
			}
			if c == '\n' {
				lx.line++
				lx.pos = Linestart
			}
		} else {
			if c == '"' {
				break
			}
			if c == Beof {
				lx.error("end of file in string constant")
				break
			}
			if c == '\n' {
				lx.error("newline in string constant")
				lx.line++
				lx.pos = Linestart
				break
			}
			if c == '\\' {
				c = lx.escchar()
				if c == Beof {
					lx.error("end of file in string constant")
					break
				}
			}
		}
		str += sys.sprint("%c", c)
	}
	return str
}

// a newline ends a statement if the last token could end one: go's
// automatic semicolon insertion rule
func endsstmt(t int) int {
	match t {
	case Eid, Econst, Erconst, Esconst, Kbreak, Kcontinue, Kreturn, Knil, Einc, Edec, ')', ']', '}', '?':
		return 1
	}
	return 0
}

// 0: a block comment consumed; '\n': a line comment to end of line;
// Beof; or -2 for a plain /
func (lx ref Lexer) lexcom() int {
	c := lx.getc()
	if c == '/' {
		for {
			c = lx.getc()
			if c == '\n' {
				return '\n'
			}
			if c == Beof {
				return Beof
			}
		}
	}
	if c == '*' {
		for {
			c = lx.getc()
			if c == Beof {
				lx.error("end of file in comment")
				return Beof
			}
			if c == '\n' {
				lx.line++
				lx.pos = Linestart
			}
			if c == '*' {
				c = lx.getc()
				if c == '/' {
					return 0
				}
				lx.ungetc()
			}
		}
	}
	lx.ungetc()
	return -2
}

func (lx ref Lexer) newline() int {
	lx.line++
	lx.pos = Linestart
	return endsstmt(lx.lasttok)
}

func (lx ref Lexer) lex(tok ref Tok) int {
	for {
		tok.line = lx.line
		tok.pos = lx.pos
		c := lx.getrune()
		match c {
		case Beof:
			if endsstmt(lx.lasttok) != 0 {
				return ';'
			}
			return Beof
		case '\n':
			if lx.newline() != 0 {
				return ';'
			}
			continue
		case ' ', '\t', '\r', 11, 12:
			continue
		case '"':
			tok.sym = lx.lexstring(0)
			return Esconst
		case '`':
			tok.sym = lx.lexstring(1)
			return Esconst
		case '\'':
			c = lx.getrune()
			if c == '\\' {
				c = lx.escchar()
			}
			if c == Beof {
				lx.error("end of file in character constant")
				return Beof
			}
			tok.ival = big(c)
			c = lx.getc()
			if c != '\'' {
				lx.error("missing closing '")
				lx.ungetc()
			}
			return Econst
		case '(', ')', '[', ']', '{', '}', ',', ';', '~', '?':
			return c
		case ':':
			c = lx.getc()
			if c == '=' {
				return Edeclas
			}
			if c == ':' {
				return Econs
			}
			lx.ungetc()
			return ':'
		case '.':
			c = lx.getc()
			if c != Beof && (cmap(c) & Mdigit) != 0 {
				lx.ungetc()
				return lx.lexnum(tok, '.')
			}
			if c == '.' {
				c = lx.getc()
				if c == '.' {
					return Edots
				}
				lx.ungetc()
				lx.error("unknown token '..'")
				return '.'
			}
			lx.ungetc()
			return '.'
		case '|':
			c = lx.getc()
			if c == '=' {
				return Eoreq
			}
			if c == '|' {
				return Eoror
			}
			lx.ungetc()
			return '|'
		case '&':
			c = lx.getc()
			if c == '=' {
				return Eandeq
			}
			if c == '&' {
				return Eandand
			}
			lx.ungetc()
			return '&'
		case '^':
			c = lx.getc()
			if c == '=' {
				return Exoreq
			}
			lx.ungetc()
			return '^'
		case '*':
			c = lx.getc()
			if c == '=' {
				return Emuleq
			}
			lx.ungetc()
			return '*'
		case '/':
			t := lx.lexcom()
			if t == 0 {
				continue
			}
			if t == '\n' {
				if lx.newline() != 0 {
					return ';'
				}
				continue
			}
			if t == Beof {
				if endsstmt(lx.lasttok) != 0 {
					return ';'
				}
				return Beof
			}
			c = lx.getc()
			if c == '=' {
				return Ediveq
			}
			lx.ungetc()
			return '/'
		case '%':
			c = lx.getc()
			if c == '=' {
				return Emodeq
			}
			lx.ungetc()
			return '%'
		case '=':
			c = lx.getc()
			if c == '=' {
				return Eeq
			}
			lx.ungetc()
			return '='
		case '!':
			c = lx.getc()
			if c == '=' {
				return Eneq
			}
			lx.ungetc()
			return '!'
		case '>':
			c = lx.getc()
			if c == '=' {
				return Egeq
			}
			if c == '>' {
				c = lx.getc()
				if c == '=' {
					return Ersheq
				}
				lx.ungetc()
				return Ersh
			}
			lx.ungetc()
			return '>'
		case '<':
			c = lx.getc()
			if c == '=' {
				return Eleq
			}
			if c == '-' {
				return Ecomm
			}
			if c == '<' {
				c = lx.getc()
				if c == '=' {
					return Elsheq
				}
				lx.ungetc()
				return Elsh
			}
			lx.ungetc()
			return '<'
		case '+':
			c = lx.getc()
			if c == '=' {
				return Eaddeq
			}
			if c == '+' {
				return Einc
			}
			lx.ungetc()
			return '+'
		case '-':
			c = lx.getc()
			if c == '=' {
				return Esubeq
			}
			if c == '-' {
				return Edec
			}
			lx.ungetc()
			return '-'
		case '0', '1', '2', '3', '4', '5', '6', '7', '8', '9':
			return lx.lexnum(tok, c)
		default:
			if (cmap(c) & Malpha) != 0 {
				return lx.lexid(tok, c)
			}
			lx.error(sys.sprint("unknown character %c", c))
			continue
		}
	}
	return Beof
}

func (lx ref Lexer) next() ref Tok {
	tok := ref Tok{t: 0, line: 0, pos: 0, sym: nil, ival: big(0), rval: 0.0, text: nil}
	tok.t = lx.lex(tok)
	lx.lasttok = tok.t
	return tok
}

func tokname(t int) string {
	match t {
	case Eandand:
		return "&&"
	case Eoror:
		return "||"
	case Eeq:
		return "=="
	case Eneq:
		return "!="
	case Eleq:
		return "<="
	case Egeq:
		return ">="
	case Elsh:
		return "<<"
	case Ersh:
		return ">>"
	case Ecomm:
		return "<-"
	case Edeclas:
		return ":="
	case Einc:
		return "++"
	case Edec:
		return "--"
	case Eaddeq:
		return "+="
	case Esubeq:
		return "-="
	case Emuleq:
		return "*="
	case Ediveq:
		return "/="
	case Emodeq:
		return "%="
	case Eandeq:
		return "&="
	case Eoreq:
		return "|="
	case Exoreq:
		return "^="
	case Elsheq:
		return "<<="
	case Ersheq:
		return ">>="
	case Edots:
		return "..."
	case Econs:
		return "::"
	case Eid:
		return "identifier"
	case Econst:
		return "integer constant"
	case Erconst:
		return "real constant"
	case Esconst:
		return "string constant"
	case Beof:
		return "eof"
	case Kalt:
		return "alt"
	case Kbreak:
		return "break"
	case Kcase:
		return "case"
	case Kchan:
		return "chan"
	case Kconst:
		return "const"
	case Kcontinue:
		return "continue"
	case Kdefault:
		return "default"
	case Kelse:
		return "else"
	case Kfor:
		return "for"
	case Kfunc:
		return "func"
	case Kif:
		return "if"
	case Kimport:
		return "import"
	case Kinterface:
		return "interface"
	case Klist:
		return "list"
	case Kload:
		return "load"
	case Kmatch:
		return "match"
	case Kmodule:
		return "module"
	case Knil:
		return "nil"
	case Kpick:
		return "pick"
	case Kref:
		return "ref"
	case Kreturn:
		return "return"
	case Kraise:
		return "raise"
	case Kspawn:
		return "spawn"
	case Kstruct:
		return "struct"
	case Ktype:
		return "type"
	case Kvar:
		return "var"
	}
	if t < 0 || t > 255 {
		return sys.sprint("token %d", t)
	}
	return sys.sprint("%c", t)
}
