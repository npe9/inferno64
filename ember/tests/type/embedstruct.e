module Embedstruct

// struct embedding: a field written as a bare type name carries its
// own fields and methods into the outer struct

import sys "sys"
import draw "draw"

type Base struct {
	id int
}

type Tagged struct {
	tag string
}

func (b ref Base) describe() string {
	return sys.sprint("base %d", b.id)
}

func (t Tagged) label() string {
	return "<" + t.tag + ">"
}

type Mid struct {
	ref Base
	Tagged
	kind int
}

type Derived struct {
	Mid
	name string
}

func show(d ref Derived) string {
	return sys.sprint("%s %s %s %d", d.name, d.describe(), d.label(), d.id)
}

func init(ctxt ref draw.Context, args list string) {
	d := ref Derived{Mid: Mid{Base: ref Base{id: 7}, Tagged: Tagged{tag: "m"}, kind: 1}, name: "x"}
	sys.print("%d %s %d %s\n", d.id, d.tag, d.kind, d.name)
	sys.print("%s\n", show(d))
	d.id = 9
	sys.print("%d %d %s\n", d.id, d.Mid.Base.id, d.describe())
	m := ref Mid{Base: ref Base{id: 1}, Tagged: Tagged{tag: "t"}, kind: 2}
	sys.print("%s %s %d\n", m.describe(), m.label(), m.id)
}
