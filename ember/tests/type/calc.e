module Calc

import sys "sys"

// a small expression calculator: a tokenizer over a string (string
// indexing, char literals, conversions), a recursive-descent parser
// building a pick-adt expression tree (constructors of every tag,
// recursion, ref returns), and an evaluator dispatching with match on
// the tags, with an error propagated as a (value, error string) pair.
// results are compared with the host's bc(1) in the golden.

type Expr pick {
	Num(val int)
	Neg(e ref Expr)
	Bin(op int, l ref Expr, r ref Expr)
}

type Parser struct {
	src string
	pos int
	err string
}

func (p ref Parser) peek() int {
	for p.pos < len(p.src) && p.src[p.pos] == ' ' {
		p.pos++
	}
	if p.pos >= len(p.src) {
		return -1
	}
	return p.src[p.pos]
}

func (p ref Parser) next() int {
	c := p.peek()
	if c >= 0 {
		p.pos++
	}
	return c
}

func (p ref Parser) number() ref Expr {
	v := 0
	for p.peek() >= '0' && p.peek() <= '9' {
		v = v * 10 + (p.next() - '0')
	}
	return ref Expr.Num{val: v}
}

func (p ref Parser) factor() ref Expr {
	c := p.peek()
	if c == '(' {
		p.next()
		e := p.expr()
		if p.next() != ')' {
			p.err = "expected )"
		}
		return e
	}
	if c == '-' {
		p.next()
		return ref Expr.Neg{e: p.factor()}
	}
	if c >= '0' && c <= '9' {
		return p.number()
	}
	p.err = sys.sprint("unexpected character at %d", p.pos)
	return ref Expr.Num{val: 0}
}

func (p ref Parser) term() ref Expr {
	e := p.factor()
	for p.peek() == '*' || p.peek() == '/' || p.peek() == '%' {
		op := p.next()
		e = ref Expr.Bin{op: op, l: e, r: p.factor()}
	}
	return e
}

func (p ref Parser) expr() ref Expr {
	e := p.term()
	for p.peek() == '+' || p.peek() == '-' {
		op := p.next()
		e = ref Expr.Bin{op: op, l: e, r: p.term()}
	}
	return e
}

func eval(e ref Expr) (int, string) {
	match e {
	case Expr.Num(v):
		return v, nil
	case Expr.Neg(x):
		v, err := eval(x)
		return -v, err
	case Expr.Bin(op, l, r):
		a, err := eval(l)
		if err != nil {
			return 0, err
		}
		b, err2 := eval(r)
		if err2 != nil {
			return 0, err2
		}
		match op {
		case '+':
			return a + b, nil
		case '-':
			return a - b, nil
		case '*':
			return a * b, nil
		case '/':
			if b == 0 {
				return 0, "division by zero"
			}
			return a / b, nil
		case '%':
			if b == 0 {
				return 0, "division by zero"
			}
			return a % b, nil
		}
	}
	return 0, "bad expression"
}

func calc(s string) string {
	p := ref Parser{src: s, pos: 0, err: nil}
	e := p.expr()
	if p.err == nil && p.peek() != -1 {
		p.err = "trailing input"
	}
	if p.err != nil {
		return "error: " + p.err
	}
	v, err := eval(e)
	if err != nil {
		return "error: " + err
	}
	return string(v)
}

func init() {
	tests := [8]string{"1 + 2 * 3", "(1 + 2) * 3", "10 / 3 * 3 + 10 % 3", "-(4 - 6) * -2", "2 * (3 + (4 - 1)) - 100 / 7", "7 / (3 - 3)", "12 +", "((15))"}
	for i := 0; i < len(tests); i++ {
		sys.print("%s = %s\n", tests[i], calc(tests[i]))
	}

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
