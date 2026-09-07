#!/bin/sh
# Emit os/osprey/pc64/<name>prog.i from one of the binaries this tree
# builds itself - the 9front-library programs of build9bin.sh - so that
# the pair personality can carry it as /boot/<name> and the buddy can
# lay it out for a container.
#
# usage: build9prog.sh name
#
# These are a different size and shape from the legacy programs beside
# them: three segments, their own main(), libthread and lib9p above the
# libc built from source in 9front/src, and a hundred kilobytes or more
# of image where a legacy program is a few tens.
set -e
test $# -eq 1 || { echo "usage: $0 name" >&2; exit 1; }
name=$1
cd "$(dirname "$0")/../../../.."
BIN=9front/amd64/bin-src/$name
# Always link, never "only if it is missing".  mk decides when this
# script runs, from the sources the pc64 mkfile names as prerequisites,
# and by the time it does run the binary left over from the last build
# is precisely the thing that must not be embedded.  Guarding the link
# on the file's existence put a stale drawsrv into a boot image and cost
# a boot to notice.
sh os/osprey/cmd/p9/build9bin.sh >/dev/null
python3 - "$PWD/os/osprey/pc64/${name}prog.i" "$BIN" "$name" <<'PY'
import sys
data=open(sys.argv[2],'rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar %sprog[]={'%sys.argv[3]]
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
