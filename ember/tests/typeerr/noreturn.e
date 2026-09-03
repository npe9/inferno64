module Noreturn

// a function with a result must return (or raise) on every path

func a(x int) int {
	if x > 0 {
		return 1
	}
}

func b(x int) int {
	match x {
	case 1:
		return 1
	case 2:
		return 2
	}
}

func c(x int) int {
	for {
		if x > 3 {
			break
		}
		x++
	}
}

func fine1(x int) int {
	if x > 0 {
		return 1
	} else {
		return 2
	}
}

func fine2(x int) int {
	match x {
	case 1:
		return 1
	default:
		raise "no"
	}
}

func fine3(x int) int {
	for {
		if x > 3 {
			return x
		}
		x++
	}
}

func fine4(x int) int {
outer:
	for {
		for {
			break
		}
		return x
	}
}
