module Booltype

import sys "sys"
import draw "draw"

// bool: comparisons and logical operators produce it, true and
// false are its constants, a condition wants it (an int flag is
// still accepted), and it converts to int as 0 or 1 -- so a
// predicate may be declared either way

func even(n int) bool {
	return n % 2 == 0
}

func all(xs []int, p func(int) bool) bool {
	for i := 0; i < len(xs); i++ {
		if !p(xs[i]) {
			return false
		}
	}
	return true
}

func count(xs []int, p func(int) bool) int {
	n := 0
	for i := 0; i < len(xs); i++ {
		n += int(p(xs[i]))
	}
	return n
}

func oldstyle(n int) int {
	return n > 2
}

func init(ctxt ref draw.Context, argv list string) {
	ok := true
	var flag bool
	sys.print("%d %d %d\n", ok, flag, even(4))
	if even(3) || flag {
		sys.print("odd\n")
	} else {
		sys.print("neither\n")
	}
	xs := [3]int{2, 4, 6}
	sys.print("%d %d %d\n", all(xs, even), all(xs, func(x int) bool { return x > 2 }), count(xs, func(x int) bool { return x > 2 }))
	n := 0
	if ok && n == 0 {
		n = int(ok) + 5
	}
	sys.print("%d %d %d\n", n, ok == true, oldstyle(n))
	for !flag {
		flag = true
	}
	sys.print("%d %d\n", flag != false, flag && oldstyle(1) != 0)
	var l list bool
	l = (1 < 2) :: false :: l
	sys.print("%d %d\n", len(l), hd(l))
}
