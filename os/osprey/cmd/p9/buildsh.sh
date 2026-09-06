#!/bin/sh
# Build the sh program and emit os/osprey/pc64/shprog.i - an ordinary
# Plan 9 binary that takes an argument vector, its file calls served by
# the buddy, embedded as /boot/sh.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9.6"
6c $LIBINC -o /tmp/shp9.6 $P/shp9.c
OBJ="$OBJ /tmp/shp9.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/sh_$m.6 lib9/$m.c
	SUP="$SUP /tmp/sh_$m.6"
done
6l -l -R4096 -o /tmp/shp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/shprog.i" <<'PY'
import sys
data=open('/tmp/shp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar shprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
