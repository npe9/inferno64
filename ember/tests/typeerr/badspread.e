module Badspread

func two() (int, string) {
	return 1, "a"
}

func f(a int, b int) int {
	return a + b
}

func g(a int) int {
	return a
}

func h(a int, b string, c int) int {
	return a + c
}

func use() int {
	return f(two()) + g(two()) + h(two())
}
