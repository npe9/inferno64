module Casttest

import sys "sys"

// type conversions, go-style "T(expr)" (and "[]byte(s)" for the one
// array target): the parser sees "int(x)" as a call to the type name
// and check.c's Ocall case rewrites it to Ocast; the conversions and
// their Dis instructions are limbo's (types.c castop()).  int(real)
// ROUNDS to nearest, as limbo's does (see the int-from-real memory).

func init() {
	// numeric
	sys.print("int(3.7)=%d int(-3.7)=%d int(2.5)=%d\n", int(3.7), int(-3.7), int(2.5))
	sys.print("real(3)=%g big(5)=%bd int(big)=%d\n", real(3), big(5), int(big(7)))
	sys.print("real(big)=%g big(2.9)=%bd\n", real(big(9)), big(2.9))
	sys.print("byte(65)=%d int(byte)=%d byte(300)=%d\n", int(byte(65)), int(byte(66)), int(byte(300)))

	// string <-> numbers
	sys.print("string(42)=%s int(\"17\")=%d int(\"abc\")=%d\n", string(42), int("17"), int("abc"))
	sys.print("string(1.5)=%s real(\"2.25\")=%g\n", string(1.5), real("2.25"))
	sys.print("string(big)=%s big(\"123456789012\")=%bd\n", string(big(99)), big("123456789012"))

	// byte <-> string/real/big go through int
	sys.print("string(byte)=%s byte(\"7\")=%d byte(3.9)=%d real(byte)=%g\n", string(byte(9)), int(byte("7")), int(byte(3.9)), real(byte(4)))

	// string <-> array of byte: utf-8 lengths
	b := []byte("héllo")
	sys.print("len=%d b0=%d b1=%d\n", len(b), int(b[0]), int(b[1]))
	sys.print("back=%s part=%s\n", string(b), string(b[0:1]))
	b[0] = byte('H')
	sys.print("mut=%s\n", string(b))

	// same-type conversion is a copy; a conversion as an argument
	// and in arithmetic
	x := 40
	sys.print("same=%d sum=%d\n", int(x), int(1.4) + int("1") + x)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
