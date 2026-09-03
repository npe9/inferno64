module Jsonlike

import sys "sys"

// a JSON-like value: a pick with a field-less tag, scalar tags, and
// tags holding lists of refs to the pick itself; a compact printer
// (recursion, string building); a parser back from the printed text
// (string scanning through a ref-receiver method, recursion,
// list building in order); round-tripped and compared as text.

type Val pick {
	Null()
	Bool(b int)
	Num(n int)
	Str(s string)
	Arr(items list ref Val)
	Obj(keys list string, vals list ref Val)
}

func print(v ref Val) string {
	match v {
	case Val.Null():
		return "null"
	case Val.Bool(b):
		if b != 0 {
			return "true"
		}
		return "false"
	case Val.Num(n):
		return string(n)
	case Val.Str(s):
		return "\"" + s + "\""
	case Val.Arr(items):
		out := "["
		first := 1
		for l := items; l != nil; l = tl(l) {
			if first == 0 {
				out += ","
			}
			first = 0
			out += print(hd(l))
		}
		return out + "]"
	case Val.Obj(keys, vals):
		out := "{"
		vl := vals
		for kl := keys; kl != nil; kl = tl(kl) {
			if kl != keys {
				out += ","
			}
			out += "\"" + hd(kl) + "\":" + print(hd(vl))
			vl = tl(vl)
		}
		return out + "}"
	}
	return "?"
}

type Parser struct {
	src string
	pos int
	err string
}

func (p ref Parser) peek() int {
	if p.pos >= len(p.src) {
		return -1
	}
	return p.src[p.pos]
}

func (p ref Parser) expect(c int) {
	if p.peek() != c {
		p.err = sys.sprint("expected %c at %d", c, p.pos)
		return
	}
	p.pos++
}

func (p ref Parser) word(w string) int {
	if p.pos + len(w) <= len(p.src) && p.src[p.pos:p.pos+len(w)] == w {
		p.pos += len(w)
		return 1
	}
	return 0
}

func (p ref Parser) str() string {
	p.expect('"')
	start := p.pos
	for p.peek() != '"' && p.peek() != -1 {
		p.pos++
	}
	s := p.src[start:p.pos]
	p.expect('"')
	return s
}

func reverse(l list ref Val) list ref Val {
	var r list ref Val
	for ; l != nil; l = tl(l) {
		r = hd(l) :: r
	}
	return r
}

func reversek(l list string) list string {
	var r list string
	for ; l != nil; l = tl(l) {
		r = hd(l) :: r
	}
	return r
}

func (p ref Parser) value() ref Val {
	if p.err != nil {
		return ref Val.Null{}
	}
	c := p.peek()
	if p.word("null") {
		return ref Val.Null{}
	}
	if p.word("true") {
		return ref Val.Bool{b: 1}
	}
	if p.word("false") {
		return ref Val.Bool{b: 0}
	}
	if c == '"' {
		return ref Val.Str{s: p.str()}
	}
	if c == '-' || (c >= '0' && c <= '9') {
		neg := 0
		if c == '-' {
			neg = 1
			p.pos++
		}
		n := 0
		for p.peek() >= '0' && p.peek() <= '9' {
			n = n * 10 + (p.peek() - '0')
			p.pos++
		}
		if neg != 0 {
			n = -n
		}
		return ref Val.Num{n: n}
	}
	if c == '[' {
		p.pos++
		var items list ref Val
		for p.peek() != ']' && p.err == nil {
			items = p.value() :: items
			if p.peek() == ',' {
				p.pos++
			}
		}
		p.expect(']')
		return ref Val.Arr{items: reverse(items)}
	}
	if c == '{' {
		p.pos++
		var keys list string
		var vals list ref Val
		for p.peek() != '}' && p.err == nil {
			k := p.str()
			p.expect(':')
			keys = k :: keys
			vals = p.value() :: vals
			if p.peek() == ',' {
				p.pos++
			}
		}
		p.expect('}')
		return ref Val.Obj{keys: reversek(keys), vals: reverse(vals)}
	}
	p.err = sys.sprint("unexpected character at %d", p.pos)
	return ref Val.Null{}
}

func init() {
	inner := ref Val.Arr{items: ref Val.Num{n: 1} :: ref Val.Num{n: -20} :: ref Val.Null{} :: nil}
	obj := ref Val.Obj{keys: "name" :: "ok" :: "list" :: "empty" :: nil,
		vals: ref Val.Str{s: "ember"} :: ref Val.Bool{b: 1} :: inner :: ref Val.Obj{keys: nil, vals: nil} :: nil}
	text := print(obj)
	sys.print("%s\n", text)

	p := ref Parser{src: text, pos: 0, err: nil}
	back := p.value()
	again := print(back)
	sys.print("roundtrip=%d err=%s\n", again == text, p.err)

	bad := ref Parser{src: "[1, 2", pos: 0, err: nil}
	bad.value()
	sys.print("bad: %s\n", bad.err)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
