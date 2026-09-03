module Fmt

// appl/cmd/fmt.b in Ember: block up paragraphs, possibly with
// indentation.  Like the Vita Nuova variant it is translated from,
// it uses a channel and a spawned parser process instead of
// accumulating words.

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

var extraindent = 0	// how many spaces to indent all lines
var indent = 0	// current value of indent, before extra indent
var length = 70	// how many columns per output line
var join = true	// can lines be joined?
var maxtab = 8
var bout ref bufio.Iobuf

type Word struct {
	text string
	indent int
	bol bool
}

func init(ctxt ref draw.Context, args list string) {
	arg.init(args)
	arg.setusage("fmt [-j] [-i indent] [-l length] [file...]")
	for {
		c := arg.opt()
		if c == 0 {
			break
		}
		match c {
		case 'i':
			extraindent = int(arg.earg())
		case 'j':
			join = false
		case 'w', 'l':
			length = int(arg.earg())
		default:
			arg.usage()
		}
	}
	args = arg.argv()
	if length <= extraindent {
		sys.fprint(sys.fildes(2), "fmt: line length<=indentation\n")
		raise "fail:length"
	}

	err := ""
	bout = bufio.fopen(sys.fildes(1), bufio.OWRITE)
	if args == nil {
		bin := bufio.fopen(sys.fildes(0), bufio.OREAD)
		fmt(bin)
	} else {
		for ; args != nil; args = tl(args) {
			bin := bufio.open(hd(args), bufio.OREAD)
			if bin == nil {
				sys.fprint(sys.fildes(2), "fmt: can't open %s: %r\n", hd(args))
				err = "open"
			} else {
				fmt(bin)
				if tl(args) != nil {
					bout.putc('\n')
				}
			}
		}
	}
	bout.flush()
	if err != nil {
		raise "fail:" + err
	}
}

func fmt(f ref bufio.Iobuf) {
	words := chan ref Word
	spawn parser(f, words)
	printwords(words)
}

func parser(f ref bufio.Iobuf, words chan ref Word) {
	for {
		s := f.gets('\n')
		if s == nil {
			break
		}
		if s[len(s) - 1] == '\n' {
			s = s[0:len(s) - 1]
		}
		parseline(s, words)
	}
	words <- nil
}

func parseline(line string, words chan ref Word) {
	var ind int
	line, ind = indentof(line)
	indent = ind
	bol := true
	for i := 0; i < len(line); {
		// find next word
		if line[i] == ' ' || line[i] == '\t' {
			i++
			continue
		}
		// where does this word end?
		l := i
		for ; l < len(line); l++ {
			if line[l] == ' ' || line[l] == '\t' {
				break
			}
		}
		words <- ref Word{text: line[i:l], indent: indent, bol: bol}
		bol = false
		i = l
	}
	if bol {
		words <- ref Word{text: "", indent: -1, bol: bol}
	}
}

func indentof(line string) (string, int) {
	ind := 0
	for i := 0; i < len(line); i++ {
		match line[i] {
		case ' ':
			ind++
		case '\t':
			ind += maxtab
			ind -= ind % maxtab
		default:
			return line, ind
		}
	}
	// plain white space doesn't change the indent
	return line, indent
}

func printwords(words chan ref Word) {
	// one output line per loop
	nw := <-words
	for nw != nil {
		w := nw
		// if it's a blank line, print it
		if w.indent == -1 {
			bout.putc('\n')
			nw = <-words
			continue
		}
		// emit leading indent
		col := extraindent + w.indent
		printindent(col)
		// emit words until overflow; always emit at least one word
		for {
			bout.puts(w.text)
			col += len(w.text)
			nw = <-words
			if nw == nil {
				break	// out of words
			}
			if nw.indent != w.indent {
				break	// indent change
			}
			nsp := nspaceafter(w.text)
			if col + nsp + len(nw.text) > extraindent + length {
				break	// fold line
			}
			if !join && nw.bol {
				break
			}
			for j := range nsp {
				bout.putc(' ')	// emit space; another word will follow
			}
			col += nsp
			w = nw
		}
		bout.putc('\n')
	}
}

func printindent(w int) {
	for w >= maxtab {
		bout.putc('\t')
		w -= maxtab
	}
	for w--; w >= 0; w-- {
		bout.putc(' ')
	}
}

// give extra space if word ends with punctuation
func nspaceafter(s string) int {
	if len(s) < 2 {
		return 1
	}
	if len(s) < 4 && s[0] >= 'A' && s[0] <= 'Z' {
		return 1	// assume it's a title, not full stop
	}
	c := s[len(s) - 1]
	if c == '.' || c == '!' || c == '?' {
		return 2
	}
	return 1
}
