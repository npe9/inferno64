module Failingtest

// a failing test is reported by name and the run fails

func test_ok() {
	expect(1 == 1, "one")
}

func test_bad() {
	expect(1 == 2, "one is two")
}

func test_after() {
	expect(true, "still runs after a failure")
}
