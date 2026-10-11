module Arithtest

// a unit test file: ember -t adds an init that runs every test_
// function, reports each failure, and ends with PASS or a failure

func add(a int, b int) int {
	return a + b
}

func test_add() {
	expect(add(2, 3) == 5, "2 + 3")
	expect(add(-1, 1) == 0, "-1 + 1")
}

func test_strings() {
	s := "ab" + "c"
	expect(len(s) == 3, "length of abc")
	expect(s[0] == 'a', "first rune")
}

func test_maps() {
	m := map[string]int{"x": 1}
	m["y"] = 2
	expect(len(m) == 2, "two entries")
	expect(m["x"] + m["y"] == 3, "sum of values")
}
