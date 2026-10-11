module Caserange

// case ranges: lo...hi over int labels, mixed with single labels

import sys "sys"
import draw "draw"

func kind(c int) string {
	match c {
	case 'a'...'z', 'A'...'Z':
		return "letter"
	case '0'...'9':
		return "digit"
	case ' ', '\t', '\n':
		return "space"
	case -10...-1:
		return "negative"
	default:
		return "other"
	}
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%s %s %s %s %s %s\n", kind('q'), kind('Z'), kind('7'), kind('\t'), kind(-3), kind('!'))
}
