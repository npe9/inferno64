#!/bin/sh
# Emit os/osprey/pc64/kbdsrvprog.i from the keyboard server this tree
# builds itself - os/osprey/cmd/draw/kbd.c linked against the 9front
# libraries in 9front/amd64/lib-src by build9bin.sh - so that the pair
# personality can carry it as /boot/kbdsrv and the buddy can lay it out
# for a container.
#
# It is the smallest of the four binaries build9bin.sh links, and it is
# first because it is the one that settles the question the others rest
# on: whether a program of this size and shape - three segments, its own
# main(), libthread and lib9p above the source-built libc - lays out,
# enters through os/osprey/pc/init9main.c and runs at all.
set -e
cd "$(dirname "$0")/../../../.."
BIN=9front/amd64/bin-src/kbdsrv
test -f "$BIN" || sh os/osprey/cmd/p9/build9bin.sh >/dev/null
python3 - "$PWD/os/osprey/pc64/kbdsrvprog.i" "$BIN" <<'PY'
import sys
data=open(sys.argv[2],'rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar kbdsrvprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
