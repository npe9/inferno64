module Wordfreq

import sys "sys"
import draw "draw"
import bufio "bufio"
import maps "maps"
import lists "lists"

// the header-only libraries together: read a file line by line,
// count words in a generic mp, sort the entries with the generic
// sort, print the top few

type Count struct {
	word string
	n int
}

func isword(c int) int {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func words(line string) list string {
	var out list string
	start := -1
	for i := 0; i <= len(line); i++ {
		if i < len(line) && isword(line[i]) != 0 {
			if start < 0 {
				start = i
			}
		} else if start >= 0 {
			out = line[start:i] :: out
			start = -1
		}
	}
	return lists.reverse(out)
}

func init(ctxt ref draw.Context, argv list string) {
	f := bufio.open("/ember/tests/type/calc.e", bufio.OREAD)
	if f == nil {
		sys.print("open failed\n")
		return
	}
	m := maps.newmap[string, int](16, maps.strhash, maps.streq)
	lines := 0
	for {
		line := f.gets('\n')
		if line == nil {
			break
		}
		lines++
		for l := words(line); l != nil; l = tl(l) {
			e := m.find(hd(l))
			if e == nil {
				m.put(hd(l), 1)
			} else {
				e.val++
			}
		}
	}
	f.close()
	counts := lists.mapl(m.keys(), func(w string) Count { return Count{word: w, n: m.find(w).val} })
	sorted := lists.sorta(lists.toarray(counts), func(a Count, b Count) int {
		if a.n != b.n {
			return a.n > b.n
		}
		return a.word < b.word
	})
	sys.print("%d lines, %d distinct words\n", lines, m.size())
	for i := 0; i < 5 && i < len(sorted); i++ {
		sys.print("%s %d\n", sorted[i].word, sorted[i].n)
	}
}
