module Usestrings

import sys "sys"
import draw "draw"
import strings "strings"

// the header-only module/strings.ei: inline functions copied into
// this module, no strings.dis

func init(ctxt ref draw.Context, argv list string) {
	s := "  Hello, Ember World  "
	t := strings.trim(s)
	sys.print("[%s] %d %d\n", t, strings.index(t, "Ember"), strings.contains(t, "xyz"))
	sys.print("%d %d\n", strings.hasprefix(t, "Hello"), strings.hassuffix(t, "World"))
	parts := strings.split("a,b,,c", ",")
	sys.print("%d [%s]\n", len(parts), strings.join(parts, "|"))
	words := strings.fields("  one two\tthree\n")
	sys.print("%d %s\n", len(words), strings.join(words, "+"))
	sys.print("%s %s %s\n", strings.tolower(t), strings.toupper("abcé"), strings.repeat("ab", 3))
	sys.print("%d %d %d\n", strings.atoi("1234"), strings.atoi("-56x"), strings.atoi(""))
	up := strings.toupper
	sys.print("%s\n", up("via value"))
}
