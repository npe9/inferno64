#!/bin/sh
# Build the unmodified legacy Plan 9 program and emit
# os/osprey/pc64/legacyprog.i.  It is an ordinary Plan 9 binary (libc,
# data segment), loaded the same data-aware way as the personality; only
# its content is a plain program that makes Plan 9 system calls.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9.6"
6c $LIBINC -o /tmp/legacyp9.6 $P/legacyp9.c
6a -o /tmp/legacyxcall.6 $P/legacyxcall.s
OBJ="$OBJ /tmp/legacyp9.6 /tmp/legacyxcall.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/legacy_$m.6 lib9/$m.c
	SUP="$SUP /tmp/legacy_$m.6"
done
6l -l -R4096 -o /tmp/legacyp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/legacyprog.i" <<'PY'
import sys
data=open('/tmp/legacyp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar legacyprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
