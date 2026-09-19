#!/bin/sh
# The 9front userland this tree builds from its own source: ten
# libraries, then rio and the draw, mouse and keyboard servers.
#
# A criterion here is a binary that exists and is a Plan 9 amd64 a.out
# entered where this kernel's loader enters one - magic 0x8a97, a
# forty-byte header, and the entry at UTZERO+0x28, which is where
# init9main.c's _main sits.  A link that produced something of another
# shape would pass a "it built" test and fail to run.
cd "$(dirname "$0")/.."
ROOT="$PWD"
PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export PATH
fail=0

say() {
	if [ "$1" = ok ]; then
		shift; echo "ok   $*"
	else
		shift; echo "FAIL $*"; fail=1
	fi
}

if sh os/osprey/cmd/p9/build9front.sh >/tmp/9lib.log 2>&1; then
	say ok "the ten 9front libraries build from the source in 9front/src, with this tree's own 6c"
else
	say no "the ten 9front libraries build from the source in 9front/src, with this tree's own 6c"
	tail -5 /tmp/9lib.log
fi

if sh os/osprey/cmd/p9/build9bin.sh >/tmp/9bin.log 2>&1; then
	say ok "and rio and the draw, mouse and keyboard servers link against them"
else
	say no "and rio and the draw, mouse and keyboard servers link against them"
	tail -5 /tmp/9bin.log
fi

for b in rio drawsrv mousesrv kbdsrv; do
	f=9front/amd64/bin-src/$b
	if [ ! -f "$f" ]; then
		say no "$b is a Plan 9 amd64 a.out entered at UTZERO+0x28"
		continue
	fi
	if python3 - "$f" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
be=lambda o,n=4:int.from_bytes(d[o:o+n],'big')
magic=be(0)
entry=be(32,8)
sys.exit(0 if magic==0x8a97 and (magic & 0x8000) and entry==0x200028 and be(4)>0 else 1)
PY
	then
		say ok "$b is a Plan 9 amd64 a.out entered at UTZERO+0x28, where the loader enters one"
	else
		say no "$b is a Plan 9 amd64 a.out entered at UTZERO+0x28, where the loader enters one"
	fi
done

exit $fail
