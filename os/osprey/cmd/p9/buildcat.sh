#!/bin/sh
# Build the cat program and emit os/osprey/pc64/catprog.i - an ordinary
# Plan 9 binary that takes an argument vector, its file calls served by
# the buddy, embedded as /boot/cat.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9.6"
6c $LIBINC -o /tmp/catp9.6 $P/catp9.c
OBJ="$OBJ /tmp/catp9.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/cat_$m.6 lib9/$m.c
	SUP="$SUP /tmp/cat_$m.6"
done
6l -l -R4096 -o /tmp/catp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/catprog.i" <<'PY'
import sys
data=open('/tmp/catp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar catprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
