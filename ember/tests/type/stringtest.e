module Stringtest

import sys "sys"
import str "string"

// the string library through module/string.ei against the real
// limbo-compiled /dis/lib/string.dis: tuple-returning imported
// functions destructured with ":=" and read through .t0/.t1, list-
// returning ones walked with hd/tl, and the import alias renamed
// ("str") since "string" is a type name.

func init() {
	head, rest := str.splitl("key=value", "=")
	sys.print("head=%s rest=%s\n", head, rest)
	sys.print("t0=%s t1=%s\n", str.splitr("a/b/c", "/").t0, str.splitr("a/b/c", "/").t1)

	n, tail := str.toint("123abc", 10)
	sys.print("n=%d tail=%s\n", n, tail)
	x, _ := str.toint("ff", 16)
	sys.print("hex=%d\n", x)

	sys.print("upper=%s lower=%s\n", str.toupper("MiXeD"), str.tolower("MiXeD"))
	sys.print("replace=%s\n", str.replace("a-b-c-d", "-", "+", 2))
	sys.print("prefix=%d contains=%d in=%d\n", str.prefix("ab", "abc"), str.contains("hello world", "o w"), str.in('c', "a-z"))

	count := 0
	for l := str.fields("  the quick  brown fox "); l != nil; l = tl(l) {
		count++
		sys.print("field %d=%s\n", count, hd(l))
	}
	sys.print("quoted=%s\n", str.quoted("a b" :: "c" :: nil))

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
