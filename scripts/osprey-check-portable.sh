#!/bin/sh
# Compile the parts of Osprey that are meant to be portable for machines
# they have never run on, and say so.
#
# os/osprey/policy/README says the layer is "kept independent of Proc,
# Mach, device drivers, and architecture trap code", and the plan says
# the same in more words.  Nothing checked it: everything in the tree
# builds it with 6c against the amd64 headers, where an assumption about
# the width of a pointer or of a long is invisible.  This builds every
# policy source with 8c against the 386 headers -- thirty-two bit, where
# such an assumption is not invisible -- and with kc against the riscv64
# headers, which is a machine of a different family altogether.
#
# The policy layer needs only u.h, pool.h and fcall.h, which is why the
# Inferno headers for those machines will do: there is no Osprey build
# for either of them and the point is not to make one.
#
# The container-side library goes with it, for 386 only: it needs a
# libc.h, and 9front has one for 386 where Inferno has lib9.h instead
# and no riscv64 tree has either.
#
# The objects are thrown away.  What is being asked is whether the
# sources compile, not whether they would link into a kernel that does
# not exist; the two trees disagree about the width of usize, which is
# why os/osprey/lib builds against the Osprey headers and this does not.
#
# usage: scripts/osprey-check-portable.sh
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH="$ROOT/MacOSX/arm64/bin:$PATH"
export PATH
TMP=`mktemp -d "${TMPDIR:-/tmp}/osprey-portable.XXXXXX"`
trap 'rm -rf "$TMP"' 0

bad=0
try() {			# try compiler objtype policyheaders [libraryheaders]
	cc=$1; ot=$2; inc=$3; lib=$4
	out=$TMP/$ot.log
	: >"$out"
	for f in "$ROOT"/os/osprey/policy/*.c; do
		"$cc" -wFV -I"$ROOT/os/osprey/policy" -I"$inc" -I"$ROOT/include" \
			-o "$TMP/o" "$f" >>"$out" 2>&1 || echo "FAILED $f" >>"$out"
	done
	if [ -n "$lib" ]; then
		# the machine's own headers first: Osprey/include holds a
		# libc.h of its own, and searching that first would give
		# the 386 compiler the amd64 one
		"$cc" -wFV -I"$ROOT/os/osprey/libosprey9" -I"$lib" \
			-I"$ROOT/9front/include" -I"$ROOT/Osprey/include" \
			-I"$ROOT/Osprey/include/osprey" -o "$TMP/o" \
			"$ROOT/os/osprey/libosprey9/osprey9.c" >>"$out" 2>&1 \
			|| echo "FAILED osprey9.c" >>"$out"
	fi
	if [ -s "$out" ]; then
		echo "FAIL the portable layer built for $ot"
		sed 's/^/     /' "$out"
		bad=1
	else
		if [ -n "$lib" ]; then
			echo "ok   the policy layer and the library built for $ot, warnings and all"
		else
			echo "ok   the policy layer built for $ot, warnings and all"
		fi
	fi
}

try 8c 386 "$ROOT/Inferno/386/include" "$ROOT/9front/386/include"
try kc riscv64 "$ROOT/Inferno/riscv64/include"

# And 9front's libc itself for 386, which is the piece a personality on
# that object type would stand on.  All 196 portable files compile; what
# the machine directory owes - the twenty-one system-call stubs, _tas,
# the 64-bit arithmetic, argv0 and _tos - is written or already in the
# tree, and os/osprey/cmd/p9/build9front386.sh puts them together.  The
# claim checked here is that the archive builds and that an ordinary
# program links against it: print, open, seek and exits, which reach
# fmt, the stubs and the vlong wrapper between them.  It does not say
# the program runs - there is no 386 personality to run it on, which is
# the piece after this one.
libc386() {
	out=$TMP/libc386.log
	: >"$out"
	if sh "$ROOT/os/osprey/cmd/p9/build9front386.sh" >>"$out" 2>&1; then
		cat > "$TMP/l.c" <<'EOF'
#include <u.h>
#include <libc.h>

void
main(int argc, char **argv)
{
	int fd;
	char buf[64];

	USED(argc); USED(argv);
	print("hello from a 386 program: argv0 %s\n", argv0 ? argv0 : "none");
	fd = open("/dev/null", OREAD);
	snprint(buf, sizeof buf, "fd %d, seek %lld", fd, seek(fd, 0, 2));
	print("%s\n", buf);
	exits(nil);
}
EOF
		INC="-I$ROOT/9front/src/include -I$ROOT/9front/386/include"
		8c $INC -o "$TMP/l.8" "$TMP/l.c" >>"$out" 2>&1 &&
		8c $INC -o "$TMP/i.8" "$ROOT/os/osprey/pc/init9main.c" >>"$out" 2>&1 &&
		8c $INC -o "$TMP/t.8" "$ROOT/os/osprey/pc/init9tos.c" >>"$out" 2>&1 &&
		8l -l -o "$TMP/l.out" "$TMP/i.8" "$TMP/t.8" "$TMP/l.8" \
			"$ROOT/9front/386/lib-src/libc9.a" >>"$out" 2>&1 || true
	fi
	# a 386 Plan 9 a.out, entered past its 32-byte header
	if [ -s "$TMP/l.out" ] &&
	   [ "`od -A n -t x1 -N 4 < "$TMP/l.out" | tr -d ' '`" = "000001eb" ]; then
		echo "ok   9front's libc builds for 386 and an ordinary program links against it"
	else
		echo "FAIL 9front's libc for 386, or a program against it"
		sed 's/^/     /' "$out"
		bad=1
	fi
}
libc386

exit $bad
