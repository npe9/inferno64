#!/bin/sh
# Build for 386 the programs the library-OS personality embeds, and emit
# them into os/osprey/pc as the amd64 scripts emit theirs into
# os/osprey/pc64.
#
# One script rather than ten, because for this object type they are ten
# instances of two shapes and nothing else.  The amd64 side has a script
# apiece, each carrying the reasoning for its program; that reasoning is
# there and is not repeated here, only the two shapes are:
#
#	a module	linked with -u, no address of its own, entered at
#			offset 0, checked by scripts/checkmodule.py: cat,
#			wc, ns, sh, reloc and rio.
#	a program	linked at an address from p9lib.h with -E p9start:
#			prog2, gen, draw and thread.  The address is the
#			base plus this machine's header, which is 32 bytes
#			where amd64's is 40 - the same difference that had
#			flat images entered eight bytes into _main.
#
# Every program is p9crt.c first (p9start at offset 0 of the text), its
# own source, p9cons-386.s for the one trap a loaded program makes, and
# the lib9 members the linker cannot read out of an archive.  They link
# against the 386 libraries os/osprey/cmd/p9/build9front386.sh builds.
#
# usage: sh os/osprey/cmd/p9/buildprogs386.sh
set -e
cd "$(dirname "$0")/../../../.."
ROOT="$PWD"
P=os/osprey/cmd/p9
K=os/osprey/pc
LIBSRC="$ROOT/9front/386/lib-src"
LIBINC="-I Osprey/386/include -I Osprey/include -I include -I $P"
THRINC="-I $ROOT/9front/src/include -I $ROOT/9front/386/include -I $ROOT/9front/src/libthread"
DRAWINC="-I $ROOT/9front/src/include -I $ROOT/9front/386/include -I $P"
RIOINC="-I$ROOT/9front/src/include -I$ROOT/9front/386/include"
TMP="$ROOT/9front/386/lib-src/prog"
mkdir -p "$TMP"
HDR=0x20		# this machine's a.out header; amd64's is 0x28

# p9crt.c and p9cons-386.s are every program's first two objects
8c $LIBINC -o "$TMP/crt.8" $P/p9crt.c
8a -o "$TMP/cons.8" $P/p9cons-386.s
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	8c $LIBINC -o "$TMP/sup_$m.8" lib9/$m.c
	SUP="$SUP $TMP/sup_$m.8"
done

# a module: name, source, and the array the personality knows it by
module() {
	name=$1; src=$2; arr=$3; extra=$4
	8c $LIBINC -o "$TMP/$name.8" "$src"
	8l -u -l -R4096 -o "$TMP/$name" "$TMP/crt.8" "$TMP/$name.8" \
		"$TMP/cons.8" $SUP $extra "$LIBSRC/libc9.a"
	python3 scripts/checkmodule.py "$TMP/$name" "$ROOT/$K/$arr.i" "$arr"
}

# A program at an address: name, source, array, base from p9lib.h, and
# whether it brings its own entry.  prog2p9.c defines p9start itself -
# the personality calls it as a function rather than starting it as a
# process, so it is not linked against p9crt.c and does not want the
# console stub either; buildprog2.sh says so at more length.
program() {
	name=$1; src=$2; arr=$3; base=$4; inc=$5; own=$6; libs=$7
	8c ${inc:-$LIBINC} -o "$TMP/$name.8" "$src"
	text=$(printf '0x%x' $((base + HDR)))
	if [ -n "$own" ]; then
		first=""; last=""
	else
		first="$TMP/crt.8"; last="$TMP/cons.8"
	fi
	8l -l -R4096 -T "$text" -E p9start -o "$TMP/$name" $first \
		"$TMP/$name.8" $last $SUP $libs "$LIBSRC/libc9.a"
	python3 - "$ROOT/$K/$arr.i" "$text" "$TMP/$name" "$arr" <<'PY'
import sys
data=open(sys.argv[3],'rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
textaddr=int(sys.argv[2],0)
if entry != textaddr:
    raise SystemExit('entry %#x is not the start of the text %#x: p9start must be linked first'
                     % (entry, textaddr))
img=data[:hdr+text+dat]
out=['uchar %s[]={' % sys.argv[4]]
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'
      % (sys.argv[1],len(img),hdr,text,dat,bss,entry))
PY
}

module libcatp9	$P/catp9.c	libcatprog
module libwcp9	$P/wcp9.c	libwcprog
module libnsp9	$P/nsp9.c	libnsprog
module libshp9	$P/shlib.c	libshprog
module relocp9	$P/relocp9.c	relocprog

# the addresses are p9lib.h's, which the personality checks at boot
program prog2p9		$P/prog2p9.c	prog2		0x1c00000 "" own
program libgenp9	$P/genp9.c	libgenprog	0x2000000
program libdrawp9	$P/drawlibp9.c	libdrawprog	0x2400000 "$DRAWINC" "" "$LIBSRC/libdraw.a"

# the threaded one takes two sources of its own
8c $THRINC -o "$TMP/thrmain.8" $P/threadmain9.c
8c $THRINC -o "$TMP/thrprog.8" $P/libthreadp9.c
text=$(printf '0x%x' $((0x2800000 + HDR)))
8l -l -R4096 -T "$text" -E p9start -o "$TMP/libthreadp9" "$TMP/crt.8" \
	"$TMP/thrmain.8" "$TMP/thrprog.8" "$TMP/cons.8" $SUP \
	"$LIBSRC/libthread.a" "$LIBSRC/libc9.a"
python3 - "$ROOT/$K/libthreadprog.i" "$text" "$TMP/libthreadp9" libthreadprog <<'PY'
import sys
data=open(sys.argv[3],'rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
textaddr=int(sys.argv[2],0)
if entry != textaddr:
    raise SystemExit('entry %#x is not the start of the text %#x' % (entry, textaddr))
img=data[:hdr+text+dat]
out=['uchar %s[]={' % sys.argv[4]]
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'
      % (sys.argv[1],len(img),hdr,text,dat,bss,entry))
PY

# rio, which is the window manager itself and wants the libraries in the
# order buildrio.sh explains: this 8l makes one pass over each archive.
8c $THRINC -o "$TMP/rio_thrmain.8" $P/threadmain9.c
8c $LIBINC -o "$TMP/rio_tokenize.8" lib9/tokenize.c
RIOOBJ=""
for f in rio data fsys scrl time util wctl wind xfid; do
	8c -I"$ROOT/9front/src/cmd/rio" $RIOINC -o "$TMP/rio_$f.8" \
		9front/src/cmd/rio/$f.c
	RIOOBJ="$RIOOBJ $TMP/rio_$f.8"
done
8l -u -l -R4096 -o "$TMP/riop9" "$TMP/crt.8" "$TMP/rio_thrmain.8" \
	"$TMP/cons.8" $SUP "$TMP/rio_tokenize.8" $RIOOBJ \
	"$LIBSRC/libframe.a" "$LIBSRC/libcomplete.a" "$LIBSRC/libdraw.a" \
	"$LIBSRC/libthread.a" "$LIBSRC/libplumb.a" "$LIBSRC/libc9.a"
python3 scripts/checkmodule.py "$TMP/riop9" "$ROOT/$K/rioprogp9.i" rioprogp9
