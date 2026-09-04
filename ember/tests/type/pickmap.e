module Pickmap

// a pick whose case holds a map or an array of the pick itself: the
// instantiation asks for the size of "ref V.Tag" while V is still
// being built

import sys "sys"
import draw "draw"

type V pick {
	Null()
	Num(n int)
	Arr(a []ref V)
	Obj(m map[string]ref V, keys []string)
}

func count(v ref V) int {
	match v {
	case V.Null:
		return 0
	case V.Num:
		return 1
	case V.Arr(a):
		n := 0
		for _, e := range a {
			n += count(e)
		}
		return n
	case V.Obj(m, keys):
		n := 0
		for _, k := range keys {
			n += count(m[k])
		}
		return n
	}
	return -1
}

func init(ctxt ref draw.Context, args list string) {
	m := map[string]ref V{}
	m["a"] = ref V.Num{n: 1}
	m["b"] = ref V.Arr{a: []ref V{ref V.Num{n: 2}, ref V.Null{}}}
	o := ref V.Obj{m: m, keys: []string{"a", "b"}}
	sys.print("%d %d\n", count(o), len(m))
	nested := ref V.Arr{a: []ref V{o, ref V.Num{n: 3}}}
	sys.print("%d\n", count(nested))
}
