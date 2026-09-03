module Wc

import sys "sys"
import bufio "bufio"
import str "string"

// a small real program across three libraries: count lines, words
// and bytes of a file through bufio, split words with the string
// library, return a struct and an error string as a pair, and report
// a missing file through the same pair.  the counts match the host
// wc(1) on the same file.

type Stats struct {
	lines int
	words int
	chars int
	longest string
}

func count(name string) (ref Stats, string) {
	f := bufio.open(name, bufio.OREAD)
	if f == nil {
		return nil, sys.sprint("cannot open %s", name)
	}
	st := ref Stats{}
	for {
		line := f.gets('\n')
		if line == nil {
			break
		}
		st.lines++
		st.chars += len(line)
		for l := str.fields(line); l != nil; l = tl(l) {
			st.words++
		}
		if len(line) > len(st.longest) {
			st.longest = line
		}
	}
	f.close()
	return st, nil
}

func init() {
	st, err := count("/ember/tests/type/hello.e")
	if err != nil {
		sys.print("%s\n", err)
		return
	}
	sys.print("%d %d %d\n", st.lines, st.words, st.chars)
	sys.print("longest: %s", st.longest)

	_, err2 := count("/no/such/file")
	sys.print("err=%s\n", err2)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
