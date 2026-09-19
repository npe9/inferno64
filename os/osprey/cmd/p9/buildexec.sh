#!/bin/sh
# Build the exec program and emit os/osprey/pc64/execprog.i - an ordinary
# Plan 9 binary that takes an argument vector, its file calls served by
# the buddy, embedded as /boot/exec.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9prog.6 os/osprey/pc64/init9tos.6"
6c $LIBINC -o /tmp/execp9.6 $P/execp9.c
OBJ="$OBJ /tmp/execp9.6"
# The four lib9 modules that used to be linked ahead of the archive are
# gone: they were a workaround for the members this linker cannot read,
# and 9front/amd64/lib-src/libc9.a - the same libc built from source with
# this tree's own 6c - answers all of them and the thirty others besides.
# The prebuilt archive stays after it, for the generated system-call
# stubs it is the only source of.
6l -l -R4096 -o /tmp/execp9 $OBJ 9front/amd64/lib-src/libc9.a Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/execprog.i" <<'PY'
import sys
data=open('/tmp/execp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar execprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
