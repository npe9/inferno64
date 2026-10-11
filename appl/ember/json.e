module Json

// a JSON reader and writer in Ember: a pick for the value, Result
// for the errors, a map for an object's members with the key order
// beside it, and a Builder for the text

import sys "sys"

type Value pick {
	Null()
	Bool(b bool)
	Num(v real)
	Str(s string)
	Arr(a []ref Value)
	Obj(keys []string, vals []ref Value)
}

type Parser struct {
	s string
	i int
}

func (p ref Parser) space() {
	for p.i < len(p.s) {
		c := p.s[p.i]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			return
		}
		p.i++
	}
}

func (p ref Parser) at() int {
	if p.i >= len(p.s) {
		return 0
	}
	return p.s[p.i]
}

func (p ref Parser) want(c int) bool {
	p.space()
	if p.at() == c {
		p.i++
		return true
	}
	return false
}

func (p ref Parser) word(w string) bool {
	if p.i + len(w) > len(p.s) {
		return false
	}
	if p.s[p.i:p.i + len(w)] != w {
		return false
	}
	p.i += len(w)
	return true
}

func (p ref Parser) str() ref Result[string] {
	if !p.want('"') {
		return ref Result[string].Err{e: "expected a string"}
	}
	b := ref Builder{}
	for p.i < len(p.s) {
		c := p.s[p.i]
		p.i++
		match {
		case c == '"':
			return ref Result[string].Ok{v: b.string()}
		case c == '\\':
			if p.i >= len(p.s) {
				break
			}
			e := p.s[p.i]
			p.i++
			match e {
			case 'n':
				b.putc('\n')
			case 't':
				b.putc('\t')
			case 'r':
				b.putc('\r')
			case 'b':
				b.putc('\b')
			case 'f':
				b.putc(12)
			case 'u':
				if p.i + 4 > len(p.s) {
					return ref Result[string].Err{e: "short \\u escape"}
				}
				n := 0
				for k := 0; k < 4; k++ {
					d := p.s[p.i + k]
					match {
					case d >= '0' && d <= '9':
						n = n * 16 + d - '0'
					case d >= 'a' && d <= 'f':
						n = n * 16 + d - 'a' + 10
					case d >= 'A' && d <= 'F':
						n = n * 16 + d - 'A' + 10
					default:
						return ref Result[string].Err{e: "bad \\u escape"}
					}
				}
				p.i += 4
				b.putc(n)
			default:
				b.putc(e)
			}
		default:
			b.putc(c)
		}
	}
	return ref Result[string].Err{e: "unterminated string"}
}

func (p ref Parser) num() ref Result[ref Value] {
	start := p.i
	if p.at() == '-' {
		p.i++
	}
	digits := 0
	for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
		p.i++
		digits++
	}
	if p.i < len(p.s) && p.s[p.i] == '.' {
		p.i++
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i++
			digits++
		}
	}
	if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
		p.i++
		if p.i < len(p.s) && (p.s[p.i] == '+' || p.s[p.i] == '-') {
			p.i++
		}
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i++
		}
	}
	if digits == 0 {
		return ref Result[ref Value].Err{e: "expected a number"}
	}
	return ref Result[ref Value].Ok{v: ref Value.Num{v: real(p.s[start:p.i])}}
}

func (p ref Parser) value() ref Result[ref Value] {
	p.space()
	match c := p.at() {
	case 0:
		return ref Result[ref Value].Err{e: "unexpected end of input"}
	case '{':
		p.i++
		var keys []string
		var vals []ref Value
		if p.want('}') {
			return ref Result[ref Value].Ok{v: ref Value.Obj{keys: keys, vals: vals}}
		}
		for {
			p.space()
			var k string
			match ks := p.str() {
			case Result[string].Err(e):
				return ref Result[ref Value].Err{e: e}
			case Result[string].Ok(v):
				k = v
			}
			if !p.want(':') {
				return ref Result[ref Value].Err{e: "expected : after a member name"}
			}
			v := p.value()?
			keys = append(keys, k)
			vals = append(vals, v)
			if p.want(',') {
				continue
			}
			if p.want('}') {
				return ref Result[ref Value].Ok{v: ref Value.Obj{keys: keys, vals: vals}}
			}
			return ref Result[ref Value].Err{e: "expected , or } in an object"}
		}
	case '[':
		p.i++
		var a []ref Value
		if p.want(']') {
			return ref Result[ref Value].Ok{v: ref Value.Arr{a: a}}
		}
		for {
			v := p.value()?
			a = append(a, v)
			if p.want(',') {
				continue
			}
			if p.want(']') {
				return ref Result[ref Value].Ok{v: ref Value.Arr{a: a}}
			}
			return ref Result[ref Value].Err{e: "expected , or ] in an array"}
		}
	case '"':
		match ss := p.str() {
		case Result[string].Err(e):
			return ref Result[ref Value].Err{e: e}
		case Result[string].Ok(v):
			return ref Result[ref Value].Ok{v: ref Value.Str{s: v}}
		}
	case 't':
		if p.word("true") {
			return ref Result[ref Value].Ok{v: ref Value.Bool{b: true}}
		}
	case 'f':
		if p.word("false") {
			return ref Result[ref Value].Ok{v: ref Value.Bool{b: false}}
		}
	case 'n':
		if p.word("null") {
			return ref Result[ref Value].Ok{v: ref Value.Null{}}
		}
	}
	return p.num()
}

// parse(s): the value s holds, or the reason it does not
func parse(s string) ref Result[ref Value] {
	p := ref Parser{s: s, i: 0}
	v := p.value()?
	p.space()
	if p.i != len(p.s) {
		return ref Result[ref Value].Err{e: "trailing text"}
	}
	return ref Result[ref Value].Ok{v: v}
}

func quote(s string, b ref Builder) {
	b.putc('"')
	for _, c := range s {
		match {
		case c == '"' || c == '\\':
			b.putc('\\')
			b.putc(c)
		case c == '\n':
			b.puts("\\n")
		case c == '\t':
			b.puts("\\t")
		case c < ' ':
			b.puts(sys.sprint("\\u%4.4x", c))
		default:
			b.putc(c)
		}
	}
	b.putc('"')
}

func write(v ref Value, b ref Builder) {
	match v {
	case Value.Null:
		b.puts("null")
	case Value.Bool(t):
		if t {
			b.puts("true")
		} else {
			b.puts("false")
		}
	case Value.Num(n):
		if n == real(int(n)) {
			b.puts(sys.sprint("%d", int(n)))
		} else {
			b.puts(sys.sprint("%g", n))
		}
	case Value.Str(s):
		quote(s, b)
	case Value.Arr(a):
		b.putc('[')
		for i, e := range a {
			if i > 0 {
				b.putc(',')
			}
			write(e, b)
		}
		b.putc(']')
	case Value.Obj(keys, vals):
		b.putc('{')
		for i, k := range keys {
			if i > 0 {
				b.putc(',')
			}
			quote(k, b)
			b.putc(':')
			write(vals[i], b)
		}
		b.putc('}')
	}
}

// text(v): v as JSON, members in the order they were read
func text(v ref Value) string {
	b := ref Builder{}
	write(v, b)
	return b.string()
}

// get(v, name): the member of an object, or nil
func get(v ref Value, name string) ref Value {
	match v {
	case Value.Obj(keys, vals):
		for i, k := range keys {
			if k == name {
				return vals[i]
			}
		}
		return nil
	}
	return nil
}

// at(v, i): the element of an array, or nil
func at(v ref Value, i int) ref Value {
	match v {
	case Value.Arr(a):
		if i < 0 || i >= len(a) {
			return nil
		}
		return a[i]
	}
	return nil
}

func writepretty(v ref Value, indent string, prefix string, b ref Builder) {
	match v {
	case Value.Arr(a):
		if len(a) == 0 {
			b.puts("[]")
			return
		}
		b.puts("[\n")
		inner := prefix + indent
		for i, e := range a {
			b.puts(inner)
			writepretty(e, indent, inner, b)
			if i < len(a) - 1 {
				b.putc(',')
			}
			b.putc('\n')
		}
		b.puts(prefix + "]")
	case Value.Obj(keys, vals):
		if len(keys) == 0 {
			b.puts("{}")
			return
		}
		b.puts("{\n")
		inner := prefix + indent
		for i, k := range keys {
			b.puts(inner)
			quote(k, b)
			b.puts(": ")
			writepretty(vals[i], indent, inner, b)
			if i < len(keys) - 1 {
				b.putc(',')
			}
			b.putc('\n')
		}
		b.puts(prefix + "}")
	default:
		write(v, b)
	}
}

// pretty(v, indent): v as JSON over several lines
func pretty(v ref Value, indent string) string {
	b := ref Builder{}
	writepretty(v, indent, "", b)
	b.putc('\n')
	return b.string()
}
