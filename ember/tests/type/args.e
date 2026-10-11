module Args

import sys "sys"
import draw "draw"

// an Ember program as an Inferno command: init takes the Command
// signature (a draw context and the argument list) and links as a
// limbo Command module, so emuinit runs it with a real argv.  under
// tests/runtime.sh it runs with no arguments through -d, so the
// output there is the no-argument case; run it by hand as
//   emu-g -r <root> '#U*<path>/args.dis' one two three
// to see the arguments echoed.

func init(ctxt ref draw.Context, argv list string) {
	n := 0
	for l := argv; l != nil; l = tl(l) {
		n++
	}
	sys.print("argc=%d\n", n)
	i := 0
	for l := argv; l != nil; l = tl(l) {
		if i > 0 {
			sys.print("arg %d: %s\n", i, hd(l))
		}
		i++
	}
	sys.print("ctxt is nil: %d\n", ctxt == nil)
}
