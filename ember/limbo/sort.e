module Sort

// appl/cmd/sort.b in Ember: sort lines, lexically or numerically

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

func usage() {
	sys.fprint(sys.fildes(2), "usage: sort [-n] [file]\n")
	raise "fail:usage"
}

const Incr = 2000	// growth quantum for record array

func init(ctxt ref draw.Context, args list string) {
	var bio ref bufio.Iobuf

	stderr := sys.fildes(2)
	nflag := false
	rflag := false
	arg.init(args)
	for {
		opt := arg.opt()
		if opt == 0 {
			break
		}
		match opt {
		case 'n':
			nflag = true
		case 'r':
			rflag = true
		default:
			usage()
		}
	}
	args = arg.argv()
	if len(args) > 1 {
		usage()
	}
	if args != nil {
		bio = bufio.open(hd(args), bufio.OREAD)
		if bio == nil {
			sys.fprint(stderr, "sort: cannot open %s: %r\n", hd(args))
			raise "fail:open file"
		}
	} else {
		bio = bufio.fopen(sys.fildes(0), bufio.OREAD)
	}
	a := [Incr]string
	n := 0
	for {
		s := bio.gets('\n')
		if s == nil {
			break
		}
		if n >= len(a) {
			b := [len(a) + Incr]string
			copy(b, a)
			a = b
		}
		a[n] = s
		n++
	}
	if nflag {
		mergesortnumeric(a, [n]string, n)
	} else {
		mergesort(a, [n]string, n)
	}

	stdout := bufio.fopen(sys.fildes(1), bufio.OWRITE)
	if rflag {
		for i := n - 1; i >= 0; i-- {
			stdout.puts(a[i])
		}
	} else {
		for i := range n {
			stdout.puts(a[i])
		}
	}
	stdout.close()
}

func mergesort(a []string, b []string, r int) {
	if r > 1 {
		m := (r - 1) / 2 + 1
		mergesort(a[0:m], b[0:m], m)
		mergesort(a[m:r], b[m:r], r - m)
		copy(b, a[0:r])
		i := 0
		j := m
		k := 0
		for ; i < m && j < r; k++ {
			if b[i] > b[j] {
				a[k] = b[j]
				j++
			} else {
				a[k] = b[i]
				i++
			}
		}
		if i < m {
			copy(a[k:], b[i:m])
		} else if j < r {
			copy(a[k:], b[j:r])
		}
	}
}

func mergesortnumeric(a []string, b []string, r int) {
	if r > 1 {
		m := (r - 1) / 2 + 1
		mergesortnumeric(a[0:m], b[0:m], m)
		mergesortnumeric(a[m:r], b[m:r], r - m)
		copy(b, a[0:r])
		i := 0
		j := m
		k := 0
		for ; i < m && j < r; k++ {
			if int(b[i]) > int(b[j]) {
				a[k] = b[j]
				j++
			} else {
				a[k] = b[i]
				i++
			}
		}
		if i < m {
			copy(a[k:], b[i:m])
		} else if j < r {
			copy(a[k:], b[j:r])
		}
	}
}
